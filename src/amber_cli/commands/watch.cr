require "../core/base_command"
require "../helpers/process_runner"
require "../helpers/sentry"
require "../static_assets"
require "../agent/find_watch_compiler"

# The `watch` command starts a development server that automatically reloads
# your application when source files change.
#
# ## Usage
# ```
# amber watch [options]
# ```
#
# With a compiler whose `watch` keeps the typed program (crystal-alpha, see
# `AmberCLI::Agent::FindWatchCompiler`), the rebuild loop is that compiler's
# `watch`: it rebuilds just what changed and restarts the app, and agent
# hooks coordinate with it (`watch hold`/`build`). Amber then only rebuilds
# static assets when `app/assets/` changes, and restarts the loop when a
# YAML config file changes. Otherwise, or with `--build`, `--run` or
# `--watch`, it polls the files and runs the build and run commands.
#
# ## Options
# - `-p, --port` - Port to run the server on (default: 3000)
# - `-e, --env` - Environment to run in (development, production)
# - `-v, --verbose` - Enable verbose output
#
# ## Examples
# ```
# # Start development server with auto-reload
# amber watch
#
# # Run on specific port
# amber watch -p 8080
#
# # Watch with verbose output
# amber watch -v
# ```
module AmberCLI::Commands
  class WatchCommand < AmberCLI::Core::BaseCommand
    getter name : String = ""
    getter build_command : String = ""
    getter run_command : String = ""
    getter watch_files : Array(String) = [] of String
    getter show_info : Bool = false

    ASSET_FILES  = ["app/assets/**/*"]
    CONFIG_FILES = ["config/**/*.yml", "config/**/*.yaml"]

    # The compiler whose `watch` runs the loop, nil for the polling loop.
    getter watch_compiler : String?

    # How the compiler is found; specs replace it.
    class_property find_watch_compiler : Proc(String?) = -> { AmberCLI::Agent::FindWatchCompiler.default }

    def help_description : String
      "Starts Amber development server and rebuilds on file changes"
    end

    def setup_command_options
      option_parser.on("-n NAME", "--name=NAME", "Sets the name of the app process") do |app_name|
        @parsed_options["name"] = app_name
        @name = app_name
      end

      option_parser.on("-b BUILD", "--build=BUILD", "Overrides the default build command") do |build|
        @parsed_options["build"] = build
        @build_command = build
      end

      option_parser.on("-r RUN", "--run=RUN", "Overrides the default run command") do |run|
        @parsed_options["run"] = run
        @run_command = run
      end

      option_parser.on("-w FILES", "--watch=FILES", "Overrides default files to watch (comma-separated)") do |files|
        @parsed_options["watch"] = files
        @watch_files = files.split(",").map(&.strip)
      end

      option_parser.on("-i", "--info", "Shows the values for build/run commands, and watched files") do
        @parsed_options["info"] = true
        @show_info = true
      end

      option_parser.separator ""
      option_parser.separator "Usage: amber watch [options]"
      option_parser.separator ""
      option_parser.separator "Examples:"
      option_parser.separator "  amber watch"
      option_parser.separator "  amber watch --name my_app"
      option_parser.separator "  amber watch --info"
      option_parser.separator "  amber watch --build 'crystal build src/my_app.cr' --run './my_app'"
    end

    def execute
      # Load defaults from config if available
      load_defaults

      if show_info
        print_info
        return
      end

      if compiler = watch_compiler
        exit run_compiler_watch(compiler)
      end

      info "Starting watch mode..."
      start_watch_process
    end

    private def load_defaults
      # Set defaults if not provided
      if @name.empty?
        @name = get_app_name
      end

      if @build_command.empty?
        @build_command = get_default_build_command
      end

      if @run_command.empty?
        @run_command = get_default_run_command
      end

      if @watch_files.empty?
        @watch_files = get_default_watch_files
      end

      custom = @parsed_options.has_key?("build") || @parsed_options.has_key?("run") || @parsed_options.has_key?("watch")
      @watch_compiler = self.class.find_watch_compiler.call unless custom
    end

    private def get_app_name
      if File.exists?(".amber.yml")
        content = File.read(".amber.yml")
        if match = content.match(/app:\s*(.+)/)
          return match[1].strip
        end
      end

      if File.exists?("shard.yml")
        content = File.read("shard.yml")
        if match = content.match(/name:\s*(.+)/)
          return match[1].strip
        end
      end

      File.basename(Dir.current)
    end

    private def get_default_build_command
      "crystal build src/#{@name}.cr -o bin/#{@name}"
    end

    private def get_default_run_command
      "./bin/#{@name}"
    end

    private def get_default_watch_files
      [
        "src/**/*.cr",
        "src/**/*.ecr",
        "config/**/*.cr",
        "config/**/*.yml",
        "config/**/*.yaml",
        "app/assets/**/*",
      ]
    end

    private def print_info
      if compiler = watch_compiler
        puts <<-INFO
        Watch Configuration:
          name:       #{@name}
          compiler:   #{compiler} watch (rebuilds what changed, restarts the app)
          assets:     amber assets build when app/assets/ changes
          restart:    #{CONFIG_FILES.join(", ")}
        INFO
        return
      end

      puts <<-INFO
      Watch Configuration:
        name:       #{@name}
        build:      #{@build_command}
        run:        #{@run_command}
        assets:     amber assets build (runs in-process before application compile)
        files:      #{@watch_files.join(", ")}
      INFO
    end

    private def start_watch_process
      build_commands = {"run" => @build_command}
      run_commands = {"run" => @run_command}
      includes = {"run" => @watch_files}
      excludes = Hash(String, Array(String)).new

      process_runner = Sentry::ProcessRunner.new(
        process_name: @name,
        before_build: -> { build_static_assets },
        build_commands: build_commands,
        run_commands: run_commands,
        includes: includes,
        excludes: excludes
      )

      info "Watching files: #{@watch_files.join(", ")}"
      info "Asset step: amber assets build (before application compile)"
      info "Build command: #{@build_command}"
      info "Run command: #{@run_command}"
      info "Press Ctrl+C to stop"

      # Handle interrupt signal
      Signal::INT.trap do
        puts "\nStopping watch process..."
        exit(0)
      end

      process_runner.run
    end

    # Runs the loop through `<compiler> watch` until interrupted, or until
    # that stops by itself. Returns the exit code.
    def run_compiler_watch(compiler : String) : Int32
      info "Asset step: amber assets build (now and when app/assets/ changes)"
      return 1 unless build_static_assets

      args = ["watch", "--run"]
      args.concat(["-o", get_default_run_command]) if AmberCLI::Agent::FindWatchCompiler.writes_output?(compiler)
      info "Rebuilds: #{compiler} #{args.join(' ')}"
      info "Press Ctrl+C to stop"

      stopping = false
      Signal::INT.trap { stopping = true }
      Signal::TERM.trap { stopping = true }

      assets = snapshot(ASSET_FILES)
      config = snapshot(CONFIG_FILES)
      process = Process.new(compiler, args, input: :inherit, output: :inherit, error: :inherit)
      until stopping
        sleep 500.milliseconds
        if process.terminated?
          status = process.wait
          error "#{compiler} watch stopped"
          return status.exit_code? || 1
        end

        current = snapshot(ASSET_FILES)
        unless current == assets
          assets = current
          build_static_assets
        end

        current = snapshot(CONFIG_FILES)
        unless current == config
          config = current
          info "Config changed: restarting #{@name}"
          stop(process)
          process = Process.new(compiler, args, input: :inherit, output: :inherit, error: :inherit)
        end
      end

      puts "\nStopping watch process..."
      stop(process)
      0
    ensure
      Signal::INT.reset
      Signal::TERM.reset
    end

    private def stop(process : Process) : Nil
      return if process.terminated?
      process.signal(:term)
      process.wait
    rescue RuntimeError
      # Already gone
    end

    # Modification times of the files matching *globs*.
    private def snapshot(globs : Array(String)) : Hash(String, Int64)
      files = {} of String => Int64
      globs.each do |glob|
        Dir.glob(glob).each do |path|
          file_info = File.info?(path)
          files[path] = file_info.modification_time.to_unix_ms if file_info && file_info.file?
        end
      end
      files
    end

    private def build_static_assets : Bool
      manifest = AmberCLI::StaticAssets.build
      info "Compiled #{manifest.assets.size} fingerprinted static assets"
      true
    rescue ex : AssetPipeline::StaticAssets::Error
      error ex.message || "Static asset build failed"
      false
    end
  end
end

# Register the command
AmberCLI::Core::CommandRegistry.register("watch", ["w"], AmberCLI::Commands::WatchCommand)
