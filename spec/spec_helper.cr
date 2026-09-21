require "spec"
require "../src/keep"

# A throwaway log path for one example.
def with_log(&)
  path = File.tempname("keep_spec", ".log")
  begin
    yield path
  ensure
    File.delete(path) if File.exists?(path)
    File.delete("#{path}.tmp") if File.exists?("#{path}.tmp")
  end
end

def append(log : Keep::Log, summary : String, kind = "ledger", &block : Keep::Log::Builder ->) : Keep::Commit
  log.append(at: "2026-09-21 16:00", origin: "spec", kind: kind, summary: summary, &block)
end
