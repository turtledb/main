require "digest/sha1"

module Bundler
  class Definition
    include GemHelpers

    attr_reader :dependencies, :platforms, :sources

    def self.build(gemfile, lockfile, unlock)
      unlock ||= {}
      gemfile = Pathname.new(gemfile).expand_path

      unless gemfile.file?
        raise GemfileNotFound, "#{gemfile} not found"
      end

      # TODO: move this back into DSL
      builder = Dsl.new
      builder.instance_eval(File.read(gemfile.to_s), gemfile.to_s, 1)
      builder.to_definition(lockfile, unlock)
    end

=begin
    How does the new system work?
    ===
    * Load information from Gemfile and Lockfile
    * Invalidate stale locked specs
      * All specs from stale source are stale
      * All specs that are reachable only through a stale
        dependency are stale.
    * If all fresh dependencies are satisfied by the locked
      specs, then we can try to resolve locally.
=end

    def initialize(lockfile, dependencies, sources, unlock)
      @dependencies, @sources, @unlock = dependencies, sources, unlock
      @remote            = false
      @specs             = nil
      @lockfile_contents = ""

      if lockfile && File.exists?(lockfile)
        @lockfile_contents = File.read(lockfile)
        locked = LockfileParser.new(@lockfile_contents)
        @platforms      = locked.platforms

        if unlock != true
          @locked_deps    = locked.dependencies
          @locked_specs   = SpecSet.new(locked.specs)
          @locked_sources = locked.sources
        else
          @unlock         = {}
          @locked_deps    = []
          @locked_specs   = SpecSet.new([])
          @locked_sources = []
        end
      else
        @unlock         = {}
        @platforms      = []
        @locked_deps    = []
        @locked_specs   = SpecSet.new([])
        @locked_sources = []
      end

      @unlock[:gems] ||= []
      @unlock[:sources] ||= []

      current_platform = Gem.platforms.map { |p| generic(p) }.compact.last
      @new_platform = !@platforms.include?(current_platform)
      @platforms |= [current_platform]

      eager_unlock = expand_dependencies(@unlock[:gems])
      @unlock[:gems] = @locked_specs.for(eager_unlock).map { |s| s.name }

      converge_sources
      converge_dependencies
    end

    def resolve_with_cache!
      raise "Specs already loaded" if @specs
      @sources.each { |s| s.cached! }
      specs
    end

    def resolve_remotely!
      raise "Specs already loaded" if @specs
      @remote = true
      @sources.each { |s| s.remote! }
      specs
    end

    def specs
      @specs ||= begin
        specs = resolve.materialize(requested_dependencies)

        unless specs["bundler"].any?
          bundler = index.search(Gem::Dependency.new('bundler', VERSION)).last
          specs["bundler"] = bundler if bundler
        end

        specs
      end
    end

    def new_specs
      specs - @locked_specs
    end

    def removed_specs
      @locked_specs - specs
    end

    def new_platform?
      @new_platform
    end

    def missing_specs
      missing = []
      resolve.materialize(requested_dependencies, missing)
      missing
    end

    def requested_specs
      @requested_specs ||= begin
        groups = self.groups - Bundler.settings.without
        groups.map! { |g| g.to_sym }
        specs_for(groups)
      end
    end

    def current_dependencies
      dependencies.reject { |d| !d.should_include? }
    end

    def specs_for(groups)
      deps = dependencies.select { |d| (d.groups & groups).any? }
      deps.delete_if { |d| !d.should_include? }
      specs.for(expand_dependencies(deps))
    end

    def resolve
      @resolve ||= begin
        if Bundler.settings[:frozen]
          @locked_specs
        else
          last_resolve = converge_locked_specs
          source_requirements = {}
          dependencies.each do |dep|
            next unless dep.source
            source_requirements[dep.name] = dep.source.specs
          end

          # Run a resolve against the locally available gems
          last_resolve.merge Resolver.resolve(expanded_dependencies, index, source_requirements, last_resolve)
        end
      end
    end

    def index
      @index ||= Index.build do |idx|
        @sources.each do |s|
          idx.use s.specs
        end
      end
    end

    def no_sources?
      @sources.length == 1 && @sources.first.remotes.empty?
    end

    def groups
      dependencies.map { |d| d.groups }.flatten.uniq
    end

    def lock(file)
      contents = to_lock

      return if @lockfile_contents == contents

      if Bundler.settings[:frozen]
        # TODO: Warn here if we got here.
        return
      end

      File.open(file, 'w') do |f|
        f.puts contents
      end
    end

    def to_lock
      out = ""

      sorted_sources.each do |source|
        # Add the source header
        out << source.to_lock
        # Find all specs for this source
        resolve.
          select  { |s| s.source == source }.
          # This needs to be sorted by full name so that
          # gems with the same name, but different platform
          # are ordered consistantly
          sort_by { |s| s.full_name }.
          each do |spec|
            next if spec.name == 'bundler'
            out << spec.to_lock
        end
        out << "\n"
      end

      out << "PLATFORMS\n"

      platforms.map { |p| p.to_s }.sort.each do |p|
        out << "  #{p}\n"
      end

      out << "\n"
      out << "DEPENDENCIES\n"

      handled = []
      dependencies.
        sort_by { |d| d.name }.
        each do |dep|
          next if handled.include?(dep.name)
          out << dep.to_lock
          handled << dep.name
      end

      out
    end

    def ensure_equivalent_gemfile_and_lockfile
      changes = false

      msg = "You have modified your Gemfile in development but did not check\n" \
            "the resulting snapshot (Gemfile.lock) into version control"

      added =   []
      deleted = []
      changed = []

      if @locked_sources != @sources
        new_sources = @sources - @locked_sources
        deleted_sources = @locked_sources - @sources

        if new_sources.any?
          added.concat new_sources.map { |source| "* source: #{source}" }
        end

        if deleted_sources.any?
          deleted.concat deleted_sources.map { |source| "* source: #{source}" }
        end

        changes = true
      end

      both_sources = Hash.new { |h,k| h[k] = ["no specified source", "no specified source"] }
      @dependencies.each { |d| both_sources[d.name][0] = d.source if d.source }
      @locked_deps.each  { |d| both_sources[d.name][1] = d.source if d.source }
      both_sources.delete_if { |k,v| v[0] == v[1] }

      if @dependencies != @locked_deps
        new_deps = @dependencies - @locked_deps
        deleted_deps = @locked_deps - @dependencies

        if new_deps.any?
          added.concat new_deps.map { |d| "* #{pretty_dep(d)}" }
        end

        if deleted_deps.any?
          deleted.concat deleted_deps.map { |d| "* #{pretty_dep(d)}" }
        end

        both_sources.each do |name, sources|
          changed << "* #{name} from `#{sources[0]}` to `#{sources[1]}`"
        end

        changes = true
      end

      msg << "\n\nYou have added to the Gemfile:\n"     << added.join("\n") if added.any?
      msg << "\n\nYou have deleted from the Gemfile:\n" << deleted.join("\n") if deleted.any?
      msg << "\n\nYou have changed in the Gemfile:\n"   << changed.join("\n") if changed.any?

      raise ProductionError, msg if added.any? || deleted.any? || changed.any?
    end

  private

    def pretty_dep(dep, source = false)
      msg  = "#{dep.name}"
      msg << " (#{dep.requirement})" unless dep.requirement == Gem::Requirement.default
      msg << " from the `#{dep.source}` source" if source && dep.source
      msg
    end

    def converge_sources
      @sources.map! do |source|
        @locked_sources.find { |s| s == source } || source
      end

      @sources.each do |source|
        source.unlock! if source.respond_to?(:unlock!) && @unlock[:sources].include?(source.name)
      end
    end

    def converge_dependencies
      (@dependencies + @locked_deps).each do |dep|
        if dep.source
          dep.source = @sources.find { |s| dep.source == s }
        end
      end
    end

    # Remove elements from the locked specs that are expired. This will most
    # commonly happen if the Gemfile has changed since the lockfile was last
    # generated
    def converge_locked_specs
      deps = []

      # Build a list of dependencies that are the same in the Gemfile
      # and Gemfile.lock. If the Gemfile modified a dependency, but
      # the gem in the Gemfile.lock still satisfies it, this is fine
      # too.
      @dependencies.each do |dep|
        locked_dep = @locked_deps.find { |d| dep == d }

        if in_locked_deps?(dep, locked_dep) || satisfies_locked_spec?(dep)
          deps << dep
        elsif dep.source.is_a?(Source::Path) && (!locked_dep || dep.source != locked_dep.source)
          @locked_specs.each do |s|
            @unlock[:gems] << s.name if s.source == dep.source
          end

          dep.source.unlock! if dep.source.respond_to?(:unlock!)
          dep.source.specs.each { |s| @unlock[:gems] << s.name }
        end
      end

      converged = []
      @locked_specs.each do |s|
        s.source = @sources.find { |src| s.source == src }

        # Don't add a spec to the list if its source is expired. For example,
        # if you change a Git gem to Rubygems.
        next if s.source.nil? || @unlock[:sources].include?(s.name)
        # If the spec is from a path source and it doesn't exist anymore
        # then we just unlock it.

        # Path sources have special logic
        if s.source.instance_of?(Source::Path)
          other = s.source.specs[s].first

          # If the spec is no longer in the path source, unlock it. This
          # commonly happens if the version changed in the gemspec
          next unless other
          # If the dependencies of the path source have changed, unlock it
          next unless s.dependencies.sort == other.dependencies.sort
        end

        converged << s
      end

      resolve = SpecSet.new(converged)
      resolve = resolve.for(expand_dependencies(deps, true), @unlock[:gems])
      diff    = @locked_specs.to_a - resolve.to_a

      # Now, we unlock any sources that do not have anymore gems pinned to it
      @sources.each do |source|
        next unless source.respond_to?(:unlock!)

        unless resolve.any? { |s| s.source == source }
          source.unlock! if diff.any? { |s| s.source == source }
        end
      end

      resolve
    end

    def in_locked_deps?(dep, d)
      d && dep.source == d.source
    end

    def satisfies_locked_spec?(dep)
      @locked_specs.any? { |s| s.satisfies?(dep) && (!dep.source || s.source == dep.source) }
    end

    def expanded_dependencies
      @expanded_dependencies ||= expand_dependencies(dependencies, @remote)
    end

    def expand_dependencies(dependencies, remote = false)
      deps = []
      dependencies.each do |dep|
        dep = Dependency.new(dep, ">= 0") unless dep.respond_to?(:name)
        dep.gem_platforms(@platforms).each do |p|
          deps << DepProxy.new(dep, p) if remote || p == generic(Gem::Platform.local)
        end
      end
      deps
    end

    def sorted_sources
      @sources.sort_by do |s|
        # Place GEM at the top
        [ s.is_a?(Source::Rubygems) ? 1 : 0, s.to_s ]
      end
    end

    def requested_dependencies
      groups = self.groups - Bundler.settings.without
      groups.map! { |g| g.to_sym }
      dependencies.reject { |d| !d.should_include? || (d.groups & groups).empty? }
    end
  end
end
