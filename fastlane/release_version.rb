require 'rubygems'

# 纯版本决策，不做网络或文件写入，便于离线验证。
module ReleaseVersion
  RELEASED = %w[READY_FOR_SALE READY_FOR_DISTRIBUTION PROCESSING_FOR_APP_STORE PROCESSING_FOR_DISTRIBUTION].freeze
  EDITABLE = %w[PREPARE_FOR_SUBMISSION DEVELOPER_REJECTED REJECTED METADATA_REJECTED INVALID_BINARY].freeze
  LOCKED = %w[WAITING_FOR_REVIEW IN_REVIEW PENDING_APPLE_RELEASE PENDING_DEVELOPER_RELEASE ACCEPTED READY_FOR_REVIEW WAITING_FOR_EXPORT_COMPLIANCE PENDING_CONTRACT].freeze

  def self.resolve(current, versions)
    published = versions.select { |v| RELEASED.include?(v[:state]) }
                        .max_by { |v| Gem::Version.new(v[:version]) }
    locked = versions.find { |v| LOCKED.include?(v[:state]) }
    raise "版本 #{locked[:version]} 当前为 #{locked[:state]}，请先处理现有审核/待发布版本" if locked
    draft = versions.select { |v| EDITABLE.include?(v[:state]) }
                    .max_by { |v| Gem::Version.new(v[:version]) }
    candidate = [current, draft && draft[:version]].compact.max_by { |v| Gem::Version.new(v) }
    if published && Gem::Version.new(candidate) <= Gem::Version.new(published[:version])
      parts = published[:version].split('.').map(&:to_i)
      parts << 0 while parts.size < 3
      parts[2] += 1
      candidate = parts.join('.')
    end
    # 曾被移除销售的版本也不能重新使用；保留原有版本，交由用户核对。
    conflict = versions.find { |v| Gem::Version.new(v[:version]) == Gem::Version.new(candidate) && !EDITABLE.include?(v[:state]) }
    raise "版本 #{candidate} 已存在且状态为 #{conflict[:state]}，无法作为新提交版本" if conflict
    { version: candidate, live: published, draft: draft }
  end
end
