require 'minitest/autorun'
require 'tmpdir'

# Load production option-building code without running a lane or authenticating.
def default_platform(*); end
def platform(*)
  yield
end
def desc(*); end
def lane(*); end
load File.expand_path('../../fastlane/Fastfile', __dir__)

class StoreOptionsTest < Minitest::Test
  def test_selected_mode_reaches_fastlane_as_boolean
    Dir.mktmpdir do |directory|
      File.write(File.join(directory, 'release-notes.txt'), '更新说明')
      state = { 'version' => '1.2', 'build' => '123' }
      automatic = store_options(directory, state.merge('release_mode' => 'automatic'), {})
      manual = store_options(directory, state.merge('release_mode' => 'manual'), {})
      assert_equal true, automatic[:automatic_release]
      assert_equal false, manual[:automatic_release]
    end
  end

  def test_missing_selection_never_defaults_to_a_release_mode
    assert_raises(RuntimeError) { store_options('/unused', {}, {}) }
  end
end
