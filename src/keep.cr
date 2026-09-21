require "c0"
require "./keep/action"
require "./keep/commit"
require "./keep/log"
require "./keep/checkpoint"

# Keep — a commit log for a file.
#
# The truth is an append-only log of *commits*, each an atomic set of typed
# *actions*. The current state is the fold of the log; a *checkpoint* caches
# that fold as of some commit. Reverting a commit appends a mark rather than
# erasing anything, so the log only ever grows and every state is reachable.
#
# The log is a C0DATA stream-mode file: one ETB-committed block per commit,
# so a crash mid-append leaves a torn tail that readers skip and the next
# writer truncates. Keep knows commits, actions, revert marks, locking and
# versions; the application supplies the action vocabulary and the fold.
module Keep
  VERSION = "0.1.0"

  # Label of the log's preamble block; bump if the layout ever changes.
  FORMAT = "keep/1"

  class Error < Exception
  end
end
