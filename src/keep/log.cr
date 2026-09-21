module Keep
  # The append-only log of commits, as a C0 stream-mode file.
  #
  #   log = Keep::Log.open("book.log")
  #   log.append(at: "2026-09-21 16:26", origin: "cli", kind: "ledger", summary: "…") do |c|
  #     c.action("record", 41, "2026-09-03", "Market run", "", ["Expenses:Food", "4820", "Assets:Checking", "-4820"])
  #   end
  #   log.each_commit(after: 38) { |commit| … }
  #   log.fold(state, after: 38) { |state, action| apply(state, action) }
  #
  # Layout: a preamble block (`GS keep/1`), then one block per commit — a
  # `commit` record followed by one record per action — each ended by ETB.
  class Log
    getter path : String

    def initialize(@path : String)
    end

    # Open a log, creating it with its preamble if it doesn't exist, and
    # truncating any torn tail left by an interrupted append.
    def self.open(path : Path | String) : Log
      log = new(path.to_s)
      log.init!
      log
    end

    protected def init! : Nil
      Dir.mkdir_p(File.dirname(@path))
      if File.exists?(@path)
        C0::Stream::Writer.repair(@path)
      else
        C0::Stream::Writer.open(@path) { |w| w.group(FORMAT) }
      end
    end

    # Run the block holding an exclusive advisory lock on the log, so two
    # processes can't assign the same sequence number. Reentrant within a
    # process only through the lock's own semantics; keep sections short.
    def lock(& : -> T) : T forall T
      File.open(@path, "a") do |f|
        f.flock_exclusive { return yield }
      end
      raise Error.new("unreachable")
    end

    # --- reading ----------------------------------------------------------

    # The sequence of the last commit (0 for an empty log).
    def version : Int64
      last = 0_i64
      each_raw { |c| last = c.seq }
      last
    end

    # Every commit, in order, with revert marks resolved.
    def commits : Array(Commit)
      all = [] of Commit
      each_raw { |c| all << c }
      resolve_reverts(all)
    end

    # Commits after `after`, in order, revert marks resolved over the whole log.
    def each_commit(after : Int64 = 0, & : Commit ->) : Nil
      commits.each { |c| yield c if c.seq > after }
    end

    def commit(seq : Int64) : Commit?
      commits.find { |c| c.seq == seq }
    end

    # True if a mark after `after` targets a commit at or before it — in
    # which case a state folded up to `after` can't be advanced by applying
    # only later commits; fold from scratch instead.
    def replay_needed?(after : Int64) : Bool
      return false if after <= 0
      commits.any? { |c| c.seq > after && (t = c.reverts || c.unreverts) && t <= after }
    end

    # Apply the actions of every non-reverted, non-mark commit after `after`
    # to `state`, in order. Returns the version folded to.
    def fold(state : T, after : Int64 = 0, & : T, Action ->) : Int64 forall T
      version = after
      each_commit(after) do |c|
        version = c.seq
        next if c.reverted? || c.mark?
        c.actions.each { |a| yield state, a }
      end
      version
    end

    # --- writing ----------------------------------------------------------

    # Append one commit. Assigns the next sequence number under the lock and
    # writes the block and its ETB as a single append.
    def append(at : String, origin : String, kind : String, summary : String, & : Builder ->) : Commit
      builder = Builder.new
      yield builder
      write(at, origin, kind, summary, builder.actions)
    end

    # Mark `seq` reverted. Raises if it doesn't exist, is itself a mark, or
    # is already reverted.
    def revert(seq : Int64, at : String, origin : String, kind : String, summary : String) : Commit
      target = commit(seq) || raise Error.new("no commit ##{seq}")
      raise Error.new("##{seq} is a revert mark") if target.mark?
      raise Error.new("##{seq} is already reverted") if target.reverted?
      write(at, origin, kind, summary, [Action.new(Commit::REVERT, seq)])
    end

    def unrevert(seq : Int64, at : String, origin : String, kind : String, summary : String) : Commit
      target = commit(seq) || raise Error.new("no commit ##{seq}")
      raise Error.new("##{seq} is not reverted") unless target.reverted?
      write(at, origin, kind, summary, [Action.new(Commit::UNREVERT, seq)])
    end

    # Collects actions for one commit.
    class Builder
      getter actions = [] of Action

      def action(name : String, *args) : Nil
        if name == Commit::REVERT || name == Commit::UNREVERT
          raise Error.new("#{name.inspect} is reserved; use Log#revert / #unrevert")
        end
        @actions << Action.new(name, *args)
      end
    end

    private def write(at : String, origin : String, kind : String, summary : String, actions : Array(Action)) : Commit
      lock do
        seq = version + 1
        C0::Stream::Writer.open(@path) do |w|
          w.batch do |b|
            b.record("commit", seq.to_s, at, origin, kind, summary)
            actions.each { |a| write_action(b, a) }
          end
        end
        Commit.new(seq, at, origin, kind, summary, actions)
      end
    end

    private def write_action(b : C0::Builder, a : Action) : Nil
      b.record(a.name)
      a.fields.each do |f|
        case f
        in String        then b.field(f)
        in Array(String) then b.nested_field(f)
        end
      end
    end

    # --- parsing ----------------------------------------------------------

    private def each_raw(& : Commit ->) : Nil
      return unless File.exists?(@path)
      reader = C0::Stream::Reader.read(@path)
      reader.each_block do |block|
        table = C0::Table.new(block)
        next if table.record_count == 0 # the preamble
        head = table.record(0)
        unless String.new(head.value(0)) == "commit"
          raise Error.new("malformed block in #{@path}: expected a commit record")
        end
        commit = Commit.new(
          String.new(head.value(1)).to_i64, String.new(head.value(2)), String.new(head.value(3)),
          String.new(head.value(4)), String.new(head.value(5)),
          (1...table.record_count).map { |i| parse_action(table.record(i)) })
        yield commit
      end
    end

    private def parse_action(rec : C0::Record) : Action
      name = String.new(rec.value(0))
      fields = (1...rec.field_count).map do |i|
        raw = rec.field(i)
        if raw.size > 0 && raw[0] == C0::STX
          parse_list(raw).as(Action::Field)
        else
          String.new(C0.unescape(raw)).as(Action::Field)
        end
      end
      Action.new(name, fields)
    end

    # The units of one STX…ETX scope, DLE-escapes honoured.
    private def parse_list(raw : Bytes) : Array(String)
      items = [] of String
      inner = raw[1, raw.size - 2] # strip STX / ETX
      start = 0
      i = 0
      while i < inner.size
        case inner[i]
        when C0::DLE then i += 2
        when C0::US
          items << String.new(C0.unescape(inner[start...i]))
          i += 1
          start = i
        else i += 1
        end
      end
      items << String.new(C0.unescape(inner[start...inner.size])) unless inner.size == 0
      items
    end

    private def resolve_reverts(all : Array(Commit)) : Array(Commit)
      by_seq = {} of Int64 => Int32
      all.each_with_index { |c, i| by_seq[c.seq] = i }
      all.each do |c|
        if t = c.reverts
          (i = by_seq[t]?) && (all[i].reverted = true)
        elsif t = c.unreverts
          (i = by_seq[t]?) && (all[i].reverted = false)
        end
      end
      all
    end
  end
end
