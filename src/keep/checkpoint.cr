require "json"

module Keep
  # A cache of the fold as of a version: `{"version": N, "state": …}`,
  # written atomically. The application owns the state's shape; keep only
  # owns the envelope, so a checkpoint always says which commit it is.
  module Checkpoint
    # Write `state_json` (any JSON value, already serialized) at `version`.
    def self.write(path : Path | String, version : Int64, state_json : String) : Nil
      path = path.to_s
      Dir.mkdir_p(File.dirname(path))
      tmp = "#{path}.tmp"
      File.open(tmp, "w") do |f|
        f << %({"version":) << version << %(,"state":) << state_json << "}\n"
      end
      File.rename(tmp, path)
    end

    # The version and state JSON of a checkpoint, or nil if there's no file.
    # Raises `Error` for a file that isn't a checkpoint (no version) — the
    # application decides what a bare document means.
    def self.read(path : Path | String) : {Int64, String}?
      path = path.to_s
      return nil unless File.exists?(path)
      doc = JSON.parse(File.read(path))
      version = doc["version"]?.try(&.as_i64?) || raise Error.new("#{path} is not a keep checkpoint (no version)")
      {version, doc["state"].to_json}
    rescue ex : JSON::ParseException
      raise Error.new("#{path} is not valid JSON: #{ex.message}")
    end
  end
end
