module AmberCLI::Agent
  # Finds a compiler whose `watch` keeps the typed program and coordinates
  # builds with agents (`watch hold`/`build`): `amber watch` hands its rebuild
  # loop to it, and the agent hooks then talk to the same watcher. Candidates
  # come in the hooks' order; the first one that coordinates wins, so an old
  # `crystal-alpha` doesn't hide a newer `crystal`.
  class FindWatchCompiler
    CANDIDATES = ["crystal-alpha", "acrystal", "crystal"]

    def self.default : String?
      new(ENV["CRYSTAL_ALPHA"]?, ->(command : String) { Process.find_executable(command) }, ->(compiler : String) { help(compiler) }).perform
    end

    # The output of `<compiler> watch --help`, nil when it can't run.
    def self.help(compiler : String) : String?
      output = IO::Memory.new
      Process.run(compiler, ["watch", "--help"], output: output, error: output)
      output.to_s
    rescue IO::Error
      nil
    end

    def initialize(@specified_path : String?, @path_lookup : Proc(String, String?), @watch_help : Proc(String, String?))
    end

    def perform : String?
      if specified_path = @specified_path.presence
        return coordinates?(specified_path) ? specified_path : nil
      end

      CANDIDATES.each do |command|
        if (executable = @path_lookup.call(command)) && coordinates?(executable)
          return executable
        end
      end
      nil
    end

    # Whether the compiler's `watch` writes the program where `-o` says.
    def self.writes_output?(compiler : String) : Bool
      !!help(compiler).try(&.includes?("--output"))
    end

    private def coordinates?(compiler : String) : Bool
      !!@watch_help.call(compiler).try(&.includes?("watch hold"))
    end
  end
end
