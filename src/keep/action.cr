module Keep
  # One effect inside a commit: a name and positional fields. A field is a
  # string or a flat list of strings (a nested C0 scope). Numbers travel as
  # text; an empty string is the absence of a value.
  struct Action
    alias Field = String | Array(String)

    getter name : String
    getter fields : Array(Field)

    def initialize(@name : String, @fields : Array(Field) = [] of Field)
    end

    # Build from loose arguments: strings, numbers, nil (→ ""), or lists.
    def self.new(name : String, *args) : Action
      fields = [] of Field
      args.each { |a| fields << Action.field(a) }
      new(name, fields)
    end

    def self.field(value) : Field
      case value
      when Nil           then ""
      when String        then value
      when Array(String) then value
      when Enumerable    then value.map(&.to_s)
      else                    value.to_s
      end
    end

    # Field `i` as a string. Raises if it's a list.
    def [](i : Int32) : String
      f = fields[i]? || ""
      f.is_a?(String) ? f : raise Error.new("field #{i} of #{name} is a list")
    end

    # Field `i` as a string, nil when absent or empty.
    def []?(i : Int32) : String?
      v = self[i]
      v.empty? ? nil : v
    end

    # Field `i` as a list (a string field becomes a one-element list; an
    # empty one, an empty list).
    def list(i : Int32) : Array(String)
      case f = fields[i]?
      when Nil    then [] of String
      when String then f.empty? ? [] of String : [f]
      else             f
      end
    end

    def size : Int32
      fields.size
    end

    def to_s(io : IO) : Nil
      io << name
      fields.each do |f|
        io << ' '
        f.is_a?(String) ? io << f.inspect : io << f.inspect
      end
    end
  end
end
