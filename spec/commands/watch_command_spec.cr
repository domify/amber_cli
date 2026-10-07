require "../amber_cli_spec"
require "../../src/amber_cli/commands/watch"

private def with_watch_compiler(compiler : String?, &)
  previous = AmberCLI::Commands::WatchCommand.find_watch_compiler
  AmberCLI::Commands::WatchCommand.find_watch_compiler = -> { compiler.as(String?) }
  begin
    yield
  ensure
    AmberCLI::Commands::WatchCommand.find_watch_compiler = previous
  end
end

# A compiler whose `watch` coordinates builds and takes `-o`; other calls are
# logged to *log* and exit at once.
private def write_watch_compiler(path : String, log : String) : Nil
  File.write(path, <<-SH)
    #!/bin/sh
    if [ "$*" = 'watch --help' ]; then
      echo '       crystal watch hold [reason]'
      echo '    -o FILE, --output FILE           Where to write the program'
      exit 0
    fi
    printf '%s\\n' "$*" >> '#{log}'
    exit 0
    SH
  File.chmod(path, 0o755)
end

describe AmberCLI::Commands::WatchCommand do
  it "watches templates and authored assets as part of the default rebuild loop" do
    SpecHelper.within_temp_directory do
      with_watch_compiler(nil) do
        command = AmberCLI::Commands::WatchCommand.new("watch")
        command.parse_and_execute(["--info"])

        command.watch_compiler.should be_nil
        command.watch_files.should contain("src/**/*.cr")
        command.watch_files.should contain("src/**/*.ecr")
        command.watch_files.should contain("app/assets/**/*")
      end
    end
  end

  it "hands the loop to a compiler whose watch coordinates builds" do
    SpecHelper.within_temp_directory do
      with_watch_compiler("/tools/crystal-alpha") do
        command = AmberCLI::Commands::WatchCommand.new("watch")
        command.parse_and_execute(["--info"])

        command.watch_compiler.should eq("/tools/crystal-alpha")
      end
    end
  end

  it "keeps the polling loop for custom build, run or watch settings" do
    SpecHelper.within_temp_directory do
      with_watch_compiler("/tools/crystal-alpha") do
        [["--build", "make"], ["--run", "./app"], ["--watch", "src/**/*.cr"]].each do |args|
          command = AmberCLI::Commands::WatchCommand.new("watch")
          command.parse_and_execute(args + ["--info"])
          command.watch_compiler.should be_nil
        end
      end
    end
  end

  it "builds the assets, then runs the compiler's watch with the app's binary" do
    SpecHelper.within_temp_directory do |project|
      File.write("shard.yml", "name: watch_app\n")
      Dir.mkdir_p("app/assets/stylesheets")
      File.write("app/assets/stylesheets/app.css", "body { color: red; }\n")
      compiler = File.join(project, "crystal-alpha")
      log = File.join(project, "calls.log")
      write_watch_compiler(compiler, log)

      with_watch_compiler(compiler) do
        command = AmberCLI::Commands::WatchCommand.new("watch")
        command.parse_and_execute(["--info"])
        # The fake compiler's watch exits at once: the loop ends with it
        command.run_compiler_watch(compiler).should eq(0)
      end

      File.read(log).should eq("watch --run -o ./bin/watch_app\n")
      File.file?("public/assets/manifest.json").should be_true
    end
  end
end

describe AmberCLI::Agent::FindWatchCompiler do
  it "takes the first candidate whose watch coordinates builds" do
    executables = {"crystal-alpha" => "/old/crystal-alpha", "crystal" => "/new/crystal"}
    help = {"/old/crystal-alpha" => "Usage: crystal watch [options]", "/new/crystal" => "crystal watch hold [reason]"}
    finder = AmberCLI::Agent::FindWatchCompiler.new(nil, ->(command : String) { executables[command]? }, ->(compiler : String) { help[compiler]? })
    finder.perform.should eq("/new/crystal")
  end

  it "finds none without a coordinating compiler, also when one is specified" do
    lookup = ->(command : String) { command == "crystal" ? "/stock/crystal" : nil }
    help = ->(compiler : String) { "Usage: crystal watch [options]".as(String?) }
    AmberCLI::Agent::FindWatchCompiler.new(nil, lookup, help).perform.should be_nil
    AmberCLI::Agent::FindWatchCompiler.new("/custom/alpha", lookup, help).perform.should be_nil
  end
end
