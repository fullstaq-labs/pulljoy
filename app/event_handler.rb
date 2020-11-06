# frozen_string_literal: true

require 'securerandom'
require 'dry-struct'
require_relative 'types'
require_relative 'github_api_types'
require_relative 'command_parser'
require_relative 'bug_error'

module Pulljoy
  class EventHandler
    SELFDIR = File.absolute_path(File.dirname(__FILE__))

    STATE_AWAITING_MANUAL_REVIEW = 'awaiting_manual_review'
    STATE_WAITING_FOR_CI = 'waiting_for_ci'
    STATE_STANDING_BY = 'standing_by'
    STATE_CLOSED = 'closed'

    class Context < Dry::Struct
      attribute :github_node_id, Types::Strict::String
      attribute :repo_full_name, Types::Strict::String
      attribute :pr_num, Types::Strict::Integer
      attribute :event_source_author, Types::Strict::String
      attribute :event_source_comment_id, Types::Strict::Integer.optional
    end

    class State < Dry::Struct
      attribute :review_id, Types::Strict::String
    end


    # @param config [Config]
    # @param reraise_unexpected_exceptions [Boolean]
    def initialize(config:, reraise_unexpected_exceptions: true)
      @config = config
      @reraise_unexpected_exceptions = reraise_unexpected_exceptions
    end

    # @param event [PullRequestEvent, IssueCommentEvent]
    def process(event)
      processed = true

      begin
        case event
        when PullRequestEvent
          set_context(
            github_node_id: event.pull_request.node_id,
            repo_full_name: event.repository.full_name,
            pr_num: event.pull_request.number,
            event_source_author: event.user.login,
          )

          case event.action
          when PullRequestEvent::ACTION_OPENED
            process_pull_request_opened_event(event)
          when PullRequestEvent::ACTION_REOPENED
            process_pull_request_reopened_event(event)
          when PullRequestEvent::ACTION_SYNCHRONIZE
            process_pull_request_synchronize_event(event)
          when PullRequestEvent::ACTION_CLOSED
            process_pull_request_closed_event(event)
          end

        when IssueCommentEvent
          set_context(
            github_node_id: event.issue.node_id,
            repo_full_name: event.repository.full_name,
            pr_num: event.issue.number,
            event_source_author: event.comment.user.login,
            event_source_comment_id: event.comment.id,
          )

          case event.action
          when IssueCommentEvent::ACTION_CREATED
            process_issue_comment_created_event(event)
          end

        else
          processed = false
        end

      rescue => e
        log_unexpected_error(e)
        raise e if @reraise_unexpected_exceptions
      end

      if !processed
        raise ArgumentError, "unsupported event type #{event.class}"
      end
    end

  private
    # @param event [PullRequestEvent]
    def process_pull_request_opened_event(event)
      review_id = generate_review_id
      request_manual_review(review_id)
      reset_state(
        state_name: STATE_AWAITING_MANUAL_REVIEW,
        review_id: review_id,
      )
    end

    # @param event [PullRequestEvent]
    def process_pull_request_reopened_event(event)
      review_id = generate_review_id
      request_manual_review(review_id)
      reset_state(
        state_name: STATE_AWAITING_MANUAL_REVIEW,
        review_id: review_id,
      )
    end

    # @param event [PullRequestEvent]
    def process_pull_request_synchronize_event(event)
      load_state

      case @state.state_name
      when STATE_AWAITING_MANUAL_REVIEW
        review_id = generate_review_id
        request_manual_review(review_id)
        update_state(review_id: review_id)

      when STATE_WAITING_FOR_CI
        cancel_ci_run(event.repository)
        delete_local_branch(event.repository)
        review_id = generate_review_id
        request_manual_review(review_id)
        update_state(review_id: review_id)

      when STATE_STANDING_BY
        review_id = generate_review_id
        request_manual_review(review_id)
        update_state(
          state: STATE_AWAITING_MANUAL_REVIEW,
          review_id: review_id,
        )

      else
        raise BugError, "in unexpected state #{@state.state_name}"
      end
    end

    # @param event [PullRequestEvent]
    def process_pull_request_closed_event(event)
      load_state
      if state.state_name == STATE_WAITING_FOR_CI
        cancel_ci_run(event.repository)
        delete_local_branch(event.repository)
      end
      reset_state
    end

    # @param event [IssueCommentEvent]
    def process_issue_comment_created_event(event)
      if is_myself?(@context.event_source_author)
        log_debug("Ignoring comment by myself")
        return
      end

      if !is_user_authorized?(@context.event_source_author)
        log_debug("Ignoring comment: user #{@context.event_source_author} not authorized to send commands")
        return
      end

      begin
        command = Pulljoy.parse_command(event.comment.body)
      rescue UnsupportedCommandType, CommandSyntaxError => e
        post_comment("Sorry @#{@context.event_source_author}: #{e}")
        return
      end

      if command.nil?
        log_debug("Ignoring comment: no command found in comment")
        return
      end

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
      load_state
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


    # @param review_id [String]
    def request_manual_review(review_id)
      post_comment('Hello maintainers, this is Pulljoy the CI bot.' \
        " Please review whether it's safe to start a CI run for this pull request." \
        ' If you deem it safe, post the following comment:' \
        " `#{COMMAND_PREFIX} approve #{review_id}`")
    end

    # @param source_repo [PullRequestRepositoryReference]
    # @param target_repo [PullRequestRepositoryReference]
    # @param commit_sha [String]
    def create_local_branch(source_repo, target_repo, commit_sha)
      Dir.mktempdir do |tmpdir|
        result, output = execute_script(
          <<~SCRIPT
            set -ex
            git clone "$SOURCE_REPO_CLONE_URL" repo
            cd repo
            git remote add target "$TARGET_REPO_PUSH_URL"
            git reset --hard "$SOURCE_REPO_COMMIT_SHA"
            git push -f target master:"$LOCAL_BRANCH_NAME"
          SCRIPT
          ,
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

    # @param repo [Repository]
    def delete_local_branch(repo)
      result, output = execute_script(
        <<~SCRIPT
          set -ex
          git push "$REPO_PUSH_URL" ":$LOCAL_BRANCH_NAME"
        SCRIPT
        ,
        env: git_auth_envvars.merge(
          REPO_PUSH_URL: infer_git_https_url(repo.full_name),
          LOCAL_BRANCH_NAME: local_branch_name
        )
      )

      if !result && output !~ /remote ref does not exist/
        raise "Error deleting branch #{local_branch_name}. Script output:\n#{output}"
      end
    end

    # @param repo [Repository]
    def cancel_ci_run(repo)
      commit_sha = @octokit.branch(repo.full_name, local_branch_name).commit.sha
      run_id = find_github_actions_run_id_for_ref(repo, commit_sha)

      if run_id.nil?
        log_debug("No Github Actions run ID found for commit #{commit_sha}")
        return
      end

      @octokit.cancel_workflow_run(repo.full_name, run_id)
    end

    # @param repo [Repository]
    # @param commit_sha [String]
    # @return [String, nil]
    def find_github_actions_run_id_for_ref(repo, commit_sha)
      runs1 = @octokit.repository_workflow_runs(repo.full_name, status: 'queued')
      runs2 = @octokit.repository_workflow_runs(repo.full_name, status: 'in_progress')
      [runs1, runs2].each do |runs|
        runs.each do |run|
          if run.head_sha == commit_sha
            return run.id
          end
        end
      end
      nil
    end


    # @param e [StandardError]
    def log_unexpected_error(e)
      if @context
        if e.is_a?(BugError)
          post_comment("@#{@context.event_source_author}" \
            " Oops, bug found in Pulljoy the CI bot:\n" \
            "~~~\n" \
            "#{e.message}\n" \
            "~~~\n" \
            "Please report this bug to the Pulljoy developers.")
        else
          post_comment("@#{@context.event_source_author}" \
            " Oops, Pulljoy the CI bot has encountered an unexpected error:\n" \
            "~~~\n" \
            "#{e.class}:\n#{e.message}\n" \
            "~~~\n")
        end
      end

      log_error('Encountered unexpected error',
        err: {
          name: e.class.to_s,
          message: e.to_s,
          stack: e.backtrace,
        })
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
        if @context.event_source_comment_id
          result[comment_id] = @context.event_source_comment_id
        end
        result
      else
        {}
      end
    end

    def set_context(*args)
      @context = Context.new(*args)
    end

    # @return [String]
    def generate_review_id
      SecureRandom.hex(5)
    end

    def load_state
      raise NotImplementedError
    end

    def reset_state(args = nil)
      if args.nil?
        raise NotImplementedError
      else
        new_state = State.new(args)
        raise NotImplementedError
      end
    end

    def update_state(args)
      new_state = State.new(@state.to_hash.merge(args))
      raise NotImplementedError
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
          GIT_ASKPASS: "#{SELFDIR}/git-askpass-helper.sh",
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

    def execute_script(script, env:, chdir: nil)
      opts = {
        in: ['/dev/null', 'r'],
        err: [:child, :out],
        close_others: true
      }
      opts[:chdir] = chdir if chdir

      output = IO.popen(env, script, 'r:utf-8', opts) do |io|
        io.read
      end
      [$?.success?, output]
    end
  end
end