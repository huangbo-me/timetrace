require 'minitest/autorun'
require_relative '../../fastlane/release_version'

class ReleaseVersionTest < Minitest::Test
  def resolve(current, version, state)
    ReleaseVersion.resolve(current, [{ version: version, state: state }])[:version]
  end

  def test_released_version_bumps_patch
    assert_equal '0.1.2', resolve('0.1.1', '0.1.1', 'READY_FOR_DISTRIBUTION')
    assert_equal '1.9.10', resolve('1.9.9', '1.9.9', 'READY_FOR_SALE')
  end

  def test_stale_local_version_uses_live_version
    assert_equal '0.2.4', resolve('0.1.1', '0.2.3', 'READY_FOR_DISTRIBUTION')
  end

  def test_two_component_version
    assert_equal '2.1.1', resolve('2.1', '2.1', 'READY_FOR_DISTRIBUTION')
  end

  def test_higher_local_version_is_preserved
    assert_equal '1.0.0', resolve('1.0.0', '0.1.1', 'READY_FOR_DISTRIBUTION')
  end

  def test_existing_newer_draft_is_reused
    versions = [{ version: '0.1.1', state: 'READY_FOR_DISTRIBUTION' },
                { version: '0.2.0', state: 'PREPARE_FOR_SUBMISSION' }]
    assert_equal '0.2.0', ReleaseVersion.resolve('0.1.1', versions)[:version]
  end

  def test_first_release
    assert_equal '0.1.1', ReleaseVersion.resolve('0.1.1', [])[:version]
  end

  def test_review_and_pending_release_are_not_overwritten
    ReleaseVersion::LOCKED.each do |state|
      assert_raises(RuntimeError) { resolve('0.1.1', '0.1.2', state) }
    end
  end

  def test_removed_or_unknown_version_is_not_reused
    %w[DEVELOPER_REMOVED_FROM_SALE REMOVED_FROM_SALE UNKNOWN_STATE].each do |state|
      assert_raises(RuntimeError) { resolve('0.1.1', '0.1.1', state) }
    end
  end
end
