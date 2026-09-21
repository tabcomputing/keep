require "./spec_helper"

describe Keep::Log do
  it "creates an empty log with its preamble and no commits" do
    with_log do |path|
      log = Keep::Log.open(path)
      log.version.should eq(0)
      log.commits.should be_empty
      File.read(path).should start_with("\u{1D}#{Keep::FORMAT}\u{17}")
    end
  end

  it "appends commits with dense sequence numbers and reads them back exactly" do
    with_log do |path|
      log = Keep::Log.open(path)
      c1 = append(log, "Market run ($48.20)") do |c|
        c.action("record", 41, "2026-09-03", "Market run", nil, ["Expenses:Food", "4820", "Assets:Checking", "-4820"])
      end
      c2 = append(log, "budget Expenses:Food = $450.00") { |c| c.action("budget", "Expenses:Food", 45000) }
      c1.seq.should eq(1)
      c2.seq.should eq(2)
      log.version.should eq(2)

      again = Keep::Log.new(path).commits
      again.map(&.seq).should eq([1, 2])
      again[0].summary.should eq("Market run ($48.20)")
      again[0].origin.should eq("spec")
      again[0].kind.should eq("ledger")
      a = again[0].actions.first
      a.name.should eq("record")
      a[0].should eq("41")
      a[1].should eq("2026-09-03")
      a[3]?.should be_nil # nil went in as "", comes out as nil
      a.list(4).should eq(["Expenses:Food", "4820", "Assets:Checking", "-4820"])
      again[1].actions.first[1].should eq("45000")
    end
  end

  it "round-trips control characters, newlines and unicode in fields and lists" do
    with_log do |path|
      log = Keep::Log.open(path)
      nasty = "tab\there\nnewline \u{1F} unit \u{1E} record \u{02}stx\u{03} ␞ ünïcödé"
      append(log, nasty) { |c| c.action("meta", nasty, [nasty, "", "b"]) }
      c = Keep::Log.new(path).commits.first
      c.summary.should eq(nasty)
      c.actions.first[0].should eq(nasty)
      c.actions.first.list(1).should eq([nasty, "", "b"])
    end
  end

  it "skips a torn tail on read and truncates it before the next append" do
    with_log do |path|
      log = Keep::Log.open(path)
      append(log, "one") { |c| c.action("a") }
      append(log, "two") { |c| c.action("b") }
      size = File.size(path)
      # simulate a crash mid-append: a partial block with no ETB
      File.open(path, "a") { |f| f << "\u{1E}commit\u{1F}3\u{1F}2026-09-21\u{1F}spec\u{1F}ledger\u{1F}torn\u{1E}c" }
      File.size(path).should be > size

      Keep::Log.new(path).commits.map(&.seq).should eq([1, 2]) # the tail is not data
      log = Keep::Log.open(path)                               # repairs
      File.size(path).should eq(size)
      append(log, "three") { |c| c.action("c") }.seq.should eq(3)
    end
  end

  it "reverts and un-reverts by appending marks; the fold skips reverted commits" do
    with_log do |path|
      log = Keep::Log.open(path)
      append(log, "one") { |c| c.action("add", 1) }
      append(log, "two") { |c| c.action("add", 2) }
      append(log, "three") { |c| c.action("add", 3) }
      log.revert(2, at: "t", origin: "spec", kind: "ledger", summary: "undo two").seq.should eq(4)

      commits = log.commits
      commits.map(&.reverted?).should eq([false, true, false, false])
      commits[3].reverts.should eq(2)
      commits[3].mark?.should be_true

      sum = [] of Int32
      log.fold(sum) { |s, a| s << a[0].to_i }.should eq(4)
      sum.should eq([1, 3])

      expect_raises(Keep::Error, /already reverted/) { log.revert(2, at: "t", origin: "spec", kind: "ledger", summary: "") }
      expect_raises(Keep::Error, /is a revert mark/) { log.revert(4, at: "t", origin: "spec", kind: "ledger", summary: "") }
      expect_raises(Keep::Error, /no commit/) { log.revert(9, at: "t", origin: "spec", kind: "ledger", summary: "") }

      log.unrevert(2, at: "t", origin: "spec", kind: "ledger", summary: "redo two").seq.should eq(5)
      sum = [] of Int32
      log.fold(sum) { |s, a| s << a[0].to_i }
      sum.should eq([1, 2, 3])
      expect_raises(Keep::Error, /not reverted/) { log.unrevert(2, at: "t", origin: "spec", kind: "ledger", summary: "") }
    end
  end

  it "reserves the mark names" do
    with_log do |path|
      log = Keep::Log.open(path)
      expect_raises(Keep::Error, /reserved/) { append(log, "x") { |c| c.action("revert", 1) } }
    end
  end

  it "folds incrementally from a version, and says when that isn't possible" do
    with_log do |path|
      log = Keep::Log.open(path)
      append(log, "one") { |c| c.action("add", 1) }
      append(log, "two") { |c| c.action("add", 2) }
      state = [] of Int32
      version = log.fold(state) { |s, a| s << a[0].to_i }
      version.should eq(2)

      append(log, "three") { |c| c.action("add", 3) }
      log.replay_needed?(version).should be_false
      log.fold(state, after: version) { |s, a| s << a[0].to_i }.should eq(3)
      state.should eq([1, 2, 3])

      log.revert(1, at: "t", origin: "spec", kind: "ledger", summary: "undo one")
      log.replay_needed?(3).should be_true # the mark reaches back past the checkpoint
      log.replay_needed?(4).should be_false
      fresh = [] of Int32
      log.fold(fresh) { |s, a| s << a[0].to_i }
      fresh.should eq([2, 3])
    end
  end

  it "serializes concurrent appends from two handles" do
    with_log do |path|
      a = Keep::Log.open(path)
      b = Keep::Log.new(path)
      append(a, "from a") { |c| c.action("x") }
      append(b, "from b") { |c| c.action("y") }
      append(a, "from a again") { |c| c.action("z") }
      Keep::Log.new(path).commits.map(&.seq).should eq([1, 2, 3])
    end
  end
end

describe Keep::Checkpoint do
  it "writes an envelope with the version and reads it back" do
    path = File.tempname("keep_ckpt", ".json")
    begin
      Keep::Checkpoint.read(path).should be_nil
      Keep::Checkpoint.write(path, 42, %({"balances":{"a":1}}))
      version, state = Keep::Checkpoint.read(path).not_nil!
      version.should eq(42)
      JSON.parse(state)["balances"]["a"].as_i.should eq(1)
      File.exists?("#{path}.tmp").should be_false

      File.write(path, %({"balances":{}}))
      expect_raises(Keep::Error, /no version/) { Keep::Checkpoint.read(path) }
    ensure
      File.delete(path) if File.exists?(path)
    end
  end
end

describe Keep::Action do
  it "coerces loose arguments into string and list fields" do
    a = Keep::Action.new("t", 7, nil, "s", [1, 2], ["x"])
    a[0].should eq("7")
    a[1].should eq("")
    a[1]?.should be_nil
    a.list(3).should eq(["1", "2"])
    a.list(0).should eq(["7"])
    a.list(1).should eq([] of String)
    expect_raises(Keep::Error, /is a list/) { a[3] }
    a.to_s.should eq(%(t "7" "" "s" ["1", "2"] ["x"]))
  end
end
