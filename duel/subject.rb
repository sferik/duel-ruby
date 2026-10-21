# frozen_string_literal: true

# The version of Duel being measured. Duel's workers are Duel themselves,
# so a version's code can't be loaded over theirs (the baseline's workers
# would measure with the baseline's Duel): it's loaded apart, under
# Subject (Subject::Duel::Stats, say), and the Duel that measures is the
# same for both.
module Subject
  class << self
    # Loads +features+ of the version at +root+: its files (duel,
    # duel/...) are evaluated here, once each, and any other library is
    # required as usual.
    def load(root, *features)
      @lib = File.join(root, "lib")
      @loaded = {}
      features.each { |feature| require feature }
    end

    def require(feature)
      path = File.join(@lib, "#{feature}.rb")
      (feature.start_with?("duel") && File.file?(path)) ? evaluate(path) : super
    end

    def require_relative(feature)
      evaluate(File.expand_path("#{feature}.rb", File.dirname(caller_locations(1, 1).first.path)))
    end

    private

    def evaluate(path)
      return false if @loaded[path]

      @loaded[path] = true
      module_eval(File.read(path), path)
      true
    end
  end
end
