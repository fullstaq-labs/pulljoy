# frozen_string_literal: true

require 'securerandom'
require 'dry-struct'
require 'active_record'
require 'composite_primary_keys'
require_relative 'github_api_types'
require_relative 'command_parser'
require_relative 'utils'

module Pulljoy
  class EventHandler
    SELFDIR = File.absolute_path(File.dirname(__FILE__))

    STATE_AWAITING_MANUAL_REVIEW = 'awaiting_manual_review'
    STATE_AWAITING_CI = 'awaiting_ci'
    STATE_STANDING_BY = 'standing_by'

    class Context < Dry::Struct
      attribute :repo_full_name, Types::Strict::String
      attribute :pr_num, Types::Strict::Integer
      attribute? :event_source_author, Types::Strict::String.optional
      attribute? :event_source_comment_id, Types::Strict::Integer.optional
    end

    class State < ActiveRecord::Base
      self.primary_keys = [:repo, :pr_num]
    end


    # @param config [Config]
    # @param octokit [Octokit::Client]
    # @param my_username [String]
    def initialize(config:, octokit:, logger:, my_username:)
      @config = config
      @octokit = octokit
      @logger = logger
      @my_username = my_username
    end

    # @param event [PullRequestEvent, IssueCommentEvent]
    def process(event)
      case event
      when PullRequestEvent
        set_context(
          repo_full_name: event.repository.full_name,
          pr_num: event.pull_request.number,
          event_source_author: event.user.login,
        )
        log_event(event)

        case event.action
        when PullRequestEvent::ACTION_OPENED
          process_pull_request_opened_event(event)
        when PullRequestEvent::ACTION_REOPENED
          process_pull_request_reopened_event(event)
        when PullRequestEvent::ACTION_SYNCHRONIZE
          process_pull_request_synchronize_event(event)
        when PullRequestEvent::ACTION_CLOSED
          process_pull_request_closed_event(event)
        else
          log_debug("Ignoring '#{event.action}' action")
        end

      when IssueCommentEvent
        set_context(
          repo_full_name: event.repository.full_name,
          pr_num: event.issue.number,
          event_source_author: event.comment.user.login,
          event_source_comment_id: event.comment.id,
        )
        log_event(event)

        case event.action
        when IssueCommentEvent::ACTION_CREATED
          process_issue_comment_created_event(event)
        else
          log_debug("Ignoring '#{event.action}' action")
        end

      when CheckSuiteEvent
        log_event(event)

        case event.action
        when CheckSuiteEvent::ACTION_COMPLETED
          process_check_suite_completed_event(event)
        else
          log_debug("Ignoring '#{event.action}' action")
        end

      else
        raise ArgumentError, "Unsupported event type #{event.class}"
      end
    end

  private
    # @param event [PullRequestEvent]
    def process_pull_request_opened_event(event)
      log_debug("Processing 'open' action")
      request_manual_review(generate_review_id)
    end

    # @param event [PullRequestEvent]
    def process_pull_request_reopened_event(event)
      log_debug("Processing 'reopen' action")
      request_manual_review(generate_review_id)
    end

    # @param event [PullRequestEvent]
    def process_pull_request_synchronize_event(event)
      log_debug("Processing 'synchronize' action")
      return if !load_state

      case @state.state_name
      when STATE_AWAITING_MANUAL_REVIEW
        review_id = generate_review_id
        request_manual_review(review_id)

      when STATE_AWAITING_CI
        cancel_ci_run
        delete_local_branch(event.repository.full_name)
        review_id = generate_review_id
        request_manual_review(review_id)

      when STATE_STANDING_BY
        review_id = generate_review_id
        request_manual_review(review_id)

      else
        raise BugError, "in unexpected state #{@state.state_name}"
      end
    end

    # @param event [PullRequestEvent]
    def process_pull_request_closed_event(event)
      log_debug("Processing 'closed' action")
      return if !load_state

      if @state.state_name == STATE_AWAITING_CI
        cancel_ci_run
        delete_local_branch(event.repository.full_name)
      end
      reset_state
    end

    # @param event [IssueCommentEvent]
    def process_issue_comment_created_event(event)
      log_debug("Processing 'created' action")
      return if !load_state

      if user_is_myself?(@context.event_source_author)
        log_debug('Ignoring comment by myself')
        return
      end
      if !user_authorized?(@context.event_source_author)
        log_debug('Ignoring comment: user not authorized to send commands',
          username: @context.event_source_author)
        return
      end

      begin
        command = Pulljoy.parse_command(event.comment.body)
      rescue UnsupportedCommandType, CommandSyntaxError => e
        post_comment("Sorry @#{@context.event_source_author}: #{e}")
        return
      end

      if command.nil?
        log_debug('Ignoring comment: no command found in comment')
        return
      end

      log_debug('Command parsed', command_type: command.class.to_s)

      case command
      when ApproveCommand
        process_approve_command(event, command)
      else
        raise BugError, "unsupported command type #{command.class}"
      end
    end

    # @param event [IssueCommentEvent]
    # @param command [ApproveCommand]
    def process_approve_command(event, command)
      return if !load_state

      if @state.state_name != STATE_AWAITING_MANUAL_REVIEW
        log_debug("Ignoring command: currently not in #{STATE_AWAITING_MANUAL_REVIEW} state")
        return
      end

      if command.review_id == @state.review_id
        pr = PullRequest.new(@octokit.pull_request(
          event.repository.full_name, event.issue.number).to_hash)
        create_local_branch(pr.head, pr.base, pr.head.sha)
      else
        post_comment("Sorry @#{@context.event_source_author}, that was the wrong review ID." \
          " Please check whether you posted the right ID, or whether the pull request needs to" \
          " be re-reviewed.")
      end
    end

    # @param event [CheckSuiteEvent]
    def process_check_suite_completed_event(event)
      log_debug("Processing 'completed' action")

      if event.check_suite.pull_requests.empty?
        log_debug('No pull requests found in this event')
        return
      end

      event.check_suite.pull_requests do |pr|
        process_check_suite_completed_event_for_pr(event, pr)
      end
    end


    # @param review_id [String]
    def request_manual_review(review_id)
      post_comment('Hello maintainers, this is Pulljoy the CI bot.' \
        " Please review whether it's safe to start a CI run for this pull request." \
        ' If you deem it safe, post the following comment:' \
        " `#{COMMAND_PREFIX} approve #{review_id}`")
      save_state(
        state_name: STATE_AWAITING_MANUAL_REVIEW,
        review_id: review_id
      )
    end

    # @param event [CheckSuiteEvent]
    # @param pr [PullRequest]
    def process_check_suite_completed_event_for_pr(event, pr)
      log_debug("Processing for PR #{pr.number}")
      set_context(
        repo_full_name: event.repository.full_name,
        pr_num: pr.number,
      )

      return if !load_state

      if @state.state_name != STATE_AWAITING_CI
        log_debug("Ignoring PR because state is not #{STATE_AWAITING_CI}",
          state: @state.state_name)
        return
      end

      if state.commit_sha != event.check_suite.commit_sha
        log_debug('Ignoring PR because the commit for which the check suite was completed, is not the one we expect',
          expected_commit: state.commit_sha,
          actual_commit: event.check_suite.commit_sha)
        return
      end

      check_suites = @octokit.
        check_suites_for_ref(repo.full_name,
          event.check_suite.head_sha).
        check_suites
      if !all_check_suites_completed?(check_suites)
        log_debug('Ignoring PR because not all check suites for this commit are completed')
        return
      end

      check_runs = @octokit.
        check_runs_for_ref(repo.full_name,
          event.check_suite.head_sha).
        check_runs

      overall_conclusion = get_overall_check_suites_conclusion(
        check_suites)
      short_sha = Pulljoy.shorten_commit_sha(event.check_suite.head_sha)
      delete_local_branch(event.repository.full_name)
      post_comment("CI run for #{short_sha} completed.\n\n" \
        " * Conclusion: #{overall_conclusion}\n" +
        render_check_run_conclusions_markdown_list(check_runs))
    end

    # rubocop:disable Metrics/MethodLength

    # @param source_repo [PullRequestRepositoryReference]
    # @param target_repo [PullRequestRepositoryReference]
    # @param commit_sha [String]
    def create_local_branch(source_repo, target_repo, commit_sha)
      Dir.mktempdir do |tmpdir|
        script = <<~SCRIPT
          set -ex
          git clone "$SOURCE_REPO_CLONE_URL" repo
          cd repo
          git remote add target "$TARGET_REPO_PUSH_URL"
          git reset --hard "$SOURCE_REPO_COMMIT_SHA"
          git push -f target master:"$LOCAL_BRANCH_NAME"
        SCRIPT
        result, output = Pulljoy.execute_script(
          script,
          env: git_auth_envvars.merge(
            SOURCE_REPO_CLONE_URL: infer_git_url(source_repo.full_name),
            SOURCE_REPO_COMMIT_SHA: commit_sha,
            TARGET_REPO_PUSH_URL: infer_git_https_url(target_repo.full_name),
            LOCAL_BRANCH_NAME: local_branch_name,
          ),
          chdir: tmpdir
        )

        if !result
          raise "Error creating branch #{local_branch_name}. Script output:\n#{output}"
        end
      end
    end

    # @param repo_full_name [String]
    # @raises [Octokit::Error]
    def delete_local_branch(repo_full_name)
      begin
        log_debug('Deleting local branch', repo: repo_full_name, brach: local_branch_name)
        @octokit.delete_ref(repo_full_name, "heads/#{local_branch_name}")
      rescue Octokit::UnprocessableEntity => e
        log_debug(
          'Github ref delete API returned 422 Unprocessable Entity',
          api_response_body: e.response_body
        )
        raise e if !error_is_ref_doesnt_exist?(e)
      end
    end

    # rubocop:enable Metrics/MethodLength

    def cancel_ci_run
      run_id = find_github_actions_run_id_for_ref(@state.repo, @state.commit_sha)

      if run_id.nil?
        log_debug(
          'No Github Actions run ID detected',
          commit: @state.commit_sha
        )
        return
      end

      log_debug(
        'Cancelling Github Actions run',
        run_id: run_id,
        commit: @state.commit_sha
      )
      @octokit.cancel_workflow_run(@context.repo_full_name, run_id)
    end

    # @param repo_full_name [String]
    # @param commit_sha [String]
    # @return [String, nil]
    def find_github_actions_run_id_for_ref(repo_full_name, commit_sha)
      ['queued', 'in_progress'].each do |status|
        @octokit.repository_workflow_runs(repo_full_name, status: status).workflow_runs.each do |run|
          return run.id if run.head_sha == commit_sha
        end
      end
      nil
    end


    # @param event [Dry::Struct]
    def log_event(event)
      log_info(
        'Processing event',
        event_class: event.class.to_s,
        event: event.to_hash,
      )
    end

    def log_error(message, props = {})
      @logger.error(message, default_logging_props.merge(props))
    end

    def log_info(message, props = {})
      @logger.info(message, default_logging_props.merge(props))
    end

    def log_debug(message, props = {})
      @logger.error(message, default_logging_props.merge(props))
    end

    def default_logging_props
      if @context
        result = {
          repo: @context.repo_full_name,
          pr_num: @context.pr_num,
        }
        result[:comment_id] = @context.event_source_comment_id if @context.event_source_comment_id
        result
      else
        {}
      end
    end

    # @param props [Hash]
    def set_context(props) # rubocop:disable Naming/AccessorMethodName
      @context = Context.new(props)
    end

    # @return [String]
    def generate_review_id
      SecureRandom.hex(5)
    end

    # Try to load the state for the current pull request.
    # Sets `@state`.
    #
    # @return [Boolean] Whether state was found.
    def load_state
      @state = State.where(
        repo: @context.repo_full_name,
        pr_num: @context.pr_num
      ).first
      if @state.nil?
        log_debug('No state found')
        false
      else
        log_debug('Loaded state', state: @state.attributes)
        true
      end
    end

    # Saves new state for the current pull request.
    #
    # @param props [Hash] All state properties to save. Any properties not listed here will be cleared.
    def save_state(props)
      if @state || load_state
        new_attrs = @state.attributes.with_indifferent_access
        new_attrs.delete('created_at')
        new_attrs.delete('updated_at')
        State.primary_keys.each do |key|
          new_attrs.delete(key)
        end
        new_attrs.each_key do |key|
          new_attrs[key] = nil
        end
        new_attrs.merge!(props)

        @state.attributes = new_attrs
        @state.save!
      else
        @state = State.create!(props.merge!(
          repo: @context.repo_full_name,
          pr_num: @context.pr_num,
        ))
      end
    end

    def reset_state
      @state.destroy!
    end

    # @return [String]
    def infer_git_url(repo_full_name)
      "git://github.com/#{repo_full_name}.git"
    end

    # @return [String]
    def infer_git_https_url(repo_full_name)
      if @config.git_auth_strategy == 'token'
        "https://token@github.com/#{repo_full_name}.git"
      else
        "https://github.com/#{repo_full_name}.git"
      end
    end

    # @return [Hash<Symbol, String>]
    def git_auth_envvars
      if @config.git_auth_strategy == 'token'
        {
          GIT_ASKPASS: "#{SELFDIR}/scripts/git-askpass-helper.sh",
          GIT_TOKEN: @config.git_auth_token
        }
      else
        {}
      end
    end

    # @return [String]
    def local_branch_name
      "pulljoy/#{@context.pr_num}"
    end

    def post_comment(message)
      @octokit.add_comment(
        @context.repo_full_name,
        @context.pr_num,
        message
      )
    end

    # @param username [String]
    # @return [Boolean]
    def user_is_myself?(username)
      username == @my_username
    end

    # @param repo [Repository]
    # @param username [String]
    # @return [Boolean]
    def user_authorized?(repo, username)
      level = @octokit.permission_level(repo.full_name, username)
      %w(admin write).include?(level)
    end

    # Checks whether this error is a "ref does not exist" error.
    #
    # @param github_ref_delete_error [Octokit::UnprocessableEntity]
    # @param [Boolean]
    def error_is_ref_doesnt_exist?(github_ref_delete_error)
      begin
        doc = JSON.parse(github_ref_delete_error.response_body)
      rescue JSON::ParserError
        log_warn(
          'Error parsing Github ref delete API error response body as JSON',
          api_response_body: e.response_body
        )
        return false
      end

      return false if !doc.is_a?(Hash) || !doc['message'].is_a?(String)

      doc['message'] =~ /Reference does not exist/
    end

    # @param check_runs [Array]
    # @return [String]
    def render_check_run_conclusions_markdown_list(check_runs)
      result = String.new
      check_runs.each do |check_run|
        case check_run.conclusion
        when 'success'
          icon = '✅'
        when 'failure', 'cancelled', 'timed_out', 'stale'
          icon = '❌'
        when 'action_required'
          icon = '⚠️'
        else
          icon = '❔'
        end
        result << " * [#{icon} #{check_run.app.name}: #{check_run.output.title}](#{check_run.html_url})\n"
      end
      result
    end

    # @param check_suites [Array]
    # @return [Boolean]
    def all_check_suites_completed?(check_suites)
      check_suites.all? do |check_suite|
        check_suite.status == 'completed'
      end
    end

    # @param check_suites [Array]
    # @return [String]
    def get_overall_check_suites_conclusion(check_suites)
      if check_suites.all? { |s| s.conclusion == 'success' }
        'success'
      else
        'failure'
      end
    end
  end
end
