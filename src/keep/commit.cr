module Keep
  # A commit: who did what, when and why, and the actions it applied.
  # `seq` is dense and ordered — assigned under the log's lock on append.
  # `reverted?` is derived when the log is read: a later `revert` mark names
  # this commit and no later `unrevert` re-instated it.
  class Commit
    getter seq : Int64
    getter at : String
    getter origin : String
    getter kind : String
    getter summary : String
    getter actions : Array(Action)
    property? reverted : Bool = false

    def initialize(@seq, @at, @origin, @kind, @summary, @actions = [] of Action)
    end

    # The commit this one reverts / re-instates, if it is such a mark.
    def reverts : Int64?
      mark_target(REVERT)
    end

    def unreverts : Int64?
      mark_target(UNREVERT)
    end

    def mark? : Bool
      !reverts.nil? || !unreverts.nil?
    end

    # Reserved action names; an application must not use them.
    REVERT   = "revert"
    UNREVERT = "unrevert"

    private def mark_target(name : String) : Int64?
      return nil unless actions.size == 1 && actions.first.name == name
      actions.first[0].to_i64?
    end
  end
end
