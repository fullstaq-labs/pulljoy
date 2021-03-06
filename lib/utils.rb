# frozen_string_literal: true

require 'dry-types'

module Pulljoy
  class BugError < StandardError; end

  module Types
    include Dry.Types()
  end

  def self.abort_with_exception(context_message, exception)
    abort("#{context_message}: #{format_error_and_backtrace(exception)}")
  end

  def self.format_error_and_backtrace(exception)
    result = String.new("#{exception} (#{exception.class})\n")
    exception.backtrace.each do |line|
      result << "    #{line}\n"
    end
    result.freeze
  end

  # Executes the given shell script and returns whether it succeeded,
  # as well as its output. Stdout and stderr are combined together.
  #
  # @param script [String]
  # @param env [Hash<Symbol, String>]
  # @param chdir [String, nil]
  # @return A tuple `(boolean, String)`
  def self.execute_script(script, env:, chdir: nil)
    opts = {
      in: ['/dev/null', 'r'],
      err: [:child, :out],
      close_others: true
    }
    opts[:chdir] = chdir if chdir

    output = IO.popen(env, script, 'r:utf-8', opts) do |io|
      io.read
    end
    [$CHILD_STATUS.success?, output]
  end

  # @param commit_sha [String]
  # @return [String]
  def self.shorten_commit_sha(commit_sha)
    commit_sha[0..7]
  end
end
