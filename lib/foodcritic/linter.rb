require 'optparse'
require 'ripper'
require 'gherkin/tag_expression'

module FoodCritic

  # The main entry point for linting your Chef cookbooks.
  class Linter

    include FoodCritic::Helpers

    # Perform option parsing from the provided arguments and do a lint check based on those arguments.
    #
    # @param [Array] args The command-line arguments to parse
    # @return [Array] Pair - the first item is string output, the second is the exit code.
    def self.check(args)
      options = {}
      options[:fail_tags] = []; options[:tags] = []
      parser = OptionParser.new do |opts|
        opts.banner = 'foodcritic [cookbook_path]'
        opts.on("-r", "--[no-]repl", "Drop into a REPL for interactive rule editing.") {|r|options[:repl] = r}
        opts.on("-t", "--tags TAGS", "Only check against rules with the specified tags.") {|t|options[:tags] << t}
        opts.on("-f", "--epic-fail TAGS", "Fail the build if any of the specified tags are matched.") {|t|options[:fail_tags] << t}
      end

      return [parser.help, 0] if args.length == 1 and args.first == '--help'

      parser.parse!(args)

      if args.length == 1 and Dir.exists?(args[0])
        review = FoodCritic::Linter.new.check(args[0], options)
        [review, review.failed? ? 3 : 0]
      else
        [parser.help, 2]
      end
    end

    # Create a new Linter.
    def initialize

    end

    # Review the cookbooks at the provided path, identifying potential improvements.
    #
    # @param [String] cookbook_path The file path to an individual cookbook directory
    # @param [Hash] options Options to apply to the linting
    # @option options [Array] tags The tags to filter rules based on
    # @option options [Array] fail_tags The tags to fail the build on
    # @return [FoodCritic::Review] A review of your cookbooks, with any warnings issued.
    def check(cookbook_path, options)
      @last_cookbook_path, @last_options = cookbook_path, options
      load_rules unless defined? @rules
      warnings = []; last_dir = nil; matched_rule_tags = Set.new
      tag_expr = Gherkin::TagExpression.new(options[:tags])

      files_to_process(cookbook_path).each do |file|
        cookbook_dir = Pathname.new(File.join(File.dirname(file), '..')).cleanpath
        ast = read_file(file)
        @rules.select{|rule| tag_expr.eval(rule.tags)}.each do |rule|
          rule_matches = matches(rule.recipe, ast, file)
          rule_matches += matches(rule.provider, ast, file) if File.basename(File.dirname(file)) == 'providers'
          rule_matches += matches(rule.resource, ast, file) if File.basename(File.dirname(file)) == 'resources'
          rule_matches += matches(rule.cookbook, cookbook_dir) if last_dir != cookbook_dir
          rule_matches.each do |match|
            warnings << Warning.new(rule, {:filename => file}.merge(match))
            matched_rule_tags += rule.tags
          end
        end
        last_dir = cookbook_dir
      end

      @review = Review.new(warnings, should_fail_build?(options[:fail_tags], matched_rule_tags))

      binding.pry if options[:repl]
      @review
    end

    # Convenience method to repeat the last check. Intended to be used from the REPL.
    def recheck
      check(@last_cookbook_path, @last_options)
    end

    # Load the rules from the (fairly unnecessary) DSL.
    def load_rules
      @rules = RuleDsl.load(File.join(File.dirname(__FILE__), 'rules.rb'), @last_options[:repl])
    end

    alias_method :reset_rules, :load_rules

    # Convenience method to retrieve the last review. Intended to be used from the REPL.
    #
    # @return [Review] The last review performed.
    def review
      @review
    end

    private

    # Invoke the DSL method with the provided parameters.
    #
    # @param [Proc] match_method Proc to invoke
    # @param params Parameters for the proc
    # @return [Array] The returned matches
    def matches(match_method, *params)
      return [] unless match_method.respond_to?(:yield)
      matches = match_method.yield(*params)
      matches.respond_to?(:each) ? matches : []
    end

    # Return the files within a cookbook tree that we are interested in trying to match rules against.
    #
    # @param [String] dir The cookbook directory
    # @return [Array] The files underneath the provided directory to be processed.
    def files_to_process(dir)
      return [dir] unless File.directory? dir
      Dir.glob(File.join(dir, '{attributes,providers,resources,recipes}/*.rb')) +
          Dir.glob(File.join(dir, '*/{attributes,providers,resources,recipes}/*.rb'))
    end

    # Whether to fail the build.
    #
    # @param [Array] fail_tags The tags that should cause the build to fail, or special value 'any' for any tag.
    # @param [Set] matched_tags The tags of warnings we have matches for
    # @return [Boolean] True if the build should be failed
    def should_fail_build?(fail_tags, matched_tags)
      if fail_tags.empty?
        false
      elsif fail_tags.include? 'any'
        true
      else
        Gherkin::TagExpression.new(fail_tags).eval(matched_tags)
      end
    end

  end
end
