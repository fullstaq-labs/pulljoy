# frozen_string_literal: true

require_relative 'spec_helper'
require 'json'
require 'stringio'
require 'octokit'
require_relative '../lib/event_handler'
require_relative '../lib/state'
require_relative '../lib/state_store/memory_store'

describe Pulljoy::EventHandler do
  before :each do
    @logio = StringIO.new
    @logger = Ougai::Logger.new(@logio)
    @logger.level = :debug
    @octokit = Octokit::Client.new(access_token: PULLJOY_TEST_CONFIG.github_access_token)
    @state_store = Pulljoy::StateStore::MemoryStore.new
  end

  let(:my_username) { 'pulljoy' }
  let(:first_review_id) { 'first-review' }

  def create_event_handler
    Pulljoy::EventHandler.new(
      config: PULLJOY_TEST_CONFIG,
      octokit: @octokit,
      logger: @logger,
      my_username: my_username,
      state_store: @state_store,
    )
  end

  def save_state(props)
    state = Pulljoy::State.new(props)
    state.validate!
    @state_store.save(props[:repo_full_name], props[:pr_num], state)
  end

  describe 'upon opening a pull request' do
    let(:event) do
      Pulljoy::PullRequestEvent.new(
        action: Pulljoy::PullRequestEvent::ACTION_OPENED,
        repository: {
          full_name: 'test/test'
        },
        user: {
          login: 'pulljoy'
        },
        pull_request: {
          number: 123,
          head: {
            sha: 'head',
            repo: {
              full_name: 'fork/test',
            }
          },
          base: {
            sha: 'base',
            repo: {
              full_name: 'test/test'
            }
          }
        }
      )
    end

    def stub_comment_post_req
      stub_request(
        :post,
        "https://api.github.com/repos/#{event.repository.full_name}/issues/#{event.pull_request.number}/comments"
      ).to_return(status: 200)
    end

    def load_state
      @state_store.load(event.repository.full_name, event.pull_request.number)
    end

    it 'requests a review' do
      comment_post_req = stub_comment_post_req.with(body: /Please review whether it's safe to start a CI run/)
      create_event_handler.process(event)
      expect(comment_post_req).to have_been_requested
    end

    it 'transitions to the awaiting_manual_review state' do
      stub_comment_post_req
      create_event_handler.process(event)

      state = load_state
      expect(state.state_name).to eq(Pulljoy::State::AWAITING_MANUAL_REVIEW)
    end
  end

  describe 'upon reopening a pull request' do
    let(:event) do
      Pulljoy::PullRequestEvent.new(
        action: Pulljoy::PullRequestEvent::ACTION_REOPENED,
        repository: {
          full_name: 'test/test'
        },
        user: {
          login: 'pulljoy'
        },
        pull_request: {
          number: 123,
          head: {
            sha: 'head',
            repo: {
              full_name: 'fork/test',
            }
          },
          base: {
            sha: 'base',
            repo: {
              full_name: 'test/test'
            }
          }
        }
      )
    end

    def stub_comment_post_req
      stub_request(
        :post,
        "https://api.github.com/repos/#{event.repository.full_name}/issues/#{event.pull_request.number}/comments"
      ).to_return(status: 200, body: '{}')
    end

    def load_state
      @state_store.load(event.repository.full_name, event.pull_request.number)
    end

    it 'requests a review' do
      comment_post_req = stub_comment_post_req.with(body: /Please review whether it's safe to start a CI run/)
      create_event_handler.process(event)
      expect(comment_post_req).to have_been_requested
    end

    it 'transitions to the awaiting_manual_review state' do
      stub_comment_post_req
      create_event_handler.process(event)

      state = load_state
      expect(state.state_name).to eq(Pulljoy::State::AWAITING_MANUAL_REVIEW)
    end
  end

  describe 'upon closing a pull request' do
    let(:event) do
      Pulljoy::PullRequestEvent.new(
        action: Pulljoy::PullRequestEvent::ACTION_CLOSED,
        repository: {
          full_name: 'test/test'
        },
        user: {
          login: 'pulljoy'
        },
        pull_request: {
          number: 123,
          head: {
            sha: 'head',
            repo: {
              full_name: 'fork/test',
            }
          },
          base: {
            sha: 'base',
            repo: {
              full_name: 'test/test'
            }
          }
        }
      )
    end

    def load_state
      @state_store.load(event.repository.full_name, event.pull_request.number)
    end

    it 'resets the state' do
      create_event_handler.process(event)
      state = load_state
      expect(state).to be_nil
    end

    describe 'when a CI build is in progress' do
      before :each do
        save_state(
          repo_full_name: event.repository.full_name,
          pr_num: event.pull_request.number,
          state_name: Pulljoy::State::AWAITING_CI,
          commit_sha: local_branch_sha,
        )
      end

      let(:local_branch_sha) { 'local' }
      let(:workflow_run_id) { 1337 }

      def stub_query_runs_req
        stub_request(
          :get,
          "https://api.github.com/repos/#{event.repository.full_name}/actions/runs?status=queued"
        ).to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(
            total_count: 1,
            workflow_runs: [
              {
                id: workflow_run_id,
                head_sha: local_branch_sha
              }
            ]
          )
        )
      end

      def stub_cancel_run_req
        stub_request(
          :post,
          "https://api.github.com/repos/#{event.repository.full_name}" \
            "/actions/runs/#{workflow_run_id}/cancel"
        ).to_return(status: 200)
      end

      def stub_delete_branch_req
        stub_request(
          :delete,
          "https://api.github.com/repos/#{event.repository.full_name}" \
            "/git/refs/heads/pulljoy/#{event.pull_request.number}"
        ).to_return(status: 200)
      end

      it 'cancels the CI build' do
        query_runs_req = stub_query_runs_req
        cancel_run_req = stub_cancel_run_req
        stub_delete_branch_req

        create_event_handler.process(event)
        expect(query_runs_req).to have_been_requested
        expect(cancel_run_req).to have_been_requested
      end

      it 'deletes the local branch' do
        stub_query_runs_req
        stub_cancel_run_req
        delete_branch_req = stub_delete_branch_req

        create_event_handler.process(event)
        expect(delete_branch_req).to have_been_requested
      end
    end
  end

  describe 'upon pushing new code' do
    let(:event) do
      Pulljoy::PullRequestEvent.new(
        action: Pulljoy::PullRequestEvent::ACTION_SYNCHRONIZE,
        repository: {
          full_name: 'test/test'
        },
        user: {
          login: 'pulljoy'
        },
        pull_request: {
          number: 123,
          head: {
            sha: 'head',
            repo: {
              full_name: 'fork/test',
            }
          },
          base: {
            sha: 'base',
            repo: {
              full_name: 'test/test'
            }
          }
        }
      )
    end

    let(:local_branch_sha) { 'local' }
    let(:workflow_run_id) { 1337 }

    def initialize_with_awaiting_manual_review_state
      save_state(
        repo_full_name: event.repository.full_name,
        pr_num: event.pull_request.number,
        state_name: Pulljoy::State::AWAITING_MANUAL_REVIEW,
        review_id: first_review_id,
      )
    end

    def initialize_with_awaiting_ci_state
      save_state(
        repo_full_name: event.repository.full_name,
        pr_num: event.pull_request.number,
        state_name: Pulljoy::State::AWAITING_CI,
        commit_sha: local_branch_sha,
      )
    end

    def stub_query_runs_req
      stub_request(
        :get,
        "https://api.github.com/repos/#{event.repository.full_name}/actions/runs?status=queued"
      ).to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(
          total_count: 1,
          workflow_runs: [
            {
              id: workflow_run_id,
              head_sha: local_branch_sha
            }
          ]
        )
      )
    end

    def stub_cancel_run_req
      stub_request(
        :post,
        "https://api.github.com/repos/#{event.repository.full_name}" \
          "/actions/runs/#{workflow_run_id}/cancel"
      ).to_return(status: 200)
    end

    def stub_delete_branch_req
      stub_request(
        :delete,
        "https://api.github.com/repos/#{event.repository.full_name}" \
          "/git/refs/heads/pulljoy/#{event.pull_request.number}"
      ).to_return(status: 200)
    end

    def stub_comment_post_req
      stub_request(
        :post,
        "https://api.github.com/repos/#{event.repository.full_name}/issues/#{event.pull_request.number}/comments"
      ).to_return(status: 200, body: '{}')
    end

    def load_state
      @state_store.load(event.repository.full_name, event.pull_request.number)
    end

    it 'cancels the previous CI build' do
      initialize_with_awaiting_ci_state

      query_runs_req = stub_query_runs_req
      cancel_run_req = stub_cancel_run_req
      stub_delete_branch_req
      stub_comment_post_req

      create_event_handler.process(event)
      expect(query_runs_req).to have_been_requested
      expect(cancel_run_req).to have_been_requested
    end

    it 'deletes the local branch' do
      initialize_with_awaiting_ci_state

      stub_query_runs_req
      stub_cancel_run_req
      delete_branch_req = stub_delete_branch_req
      stub_comment_post_req

      create_event_handler.process(event)
      expect(delete_branch_req).to have_been_requested
    end

    it 'requests a review' do
      initialize_with_awaiting_manual_review_state
      comment_post_req = stub_comment_post_req.with(body: /Please review whether it's safe to start a CI run/)

      create_event_handler.process(event)

      expect(comment_post_req).to have_been_requested
    end

    it 'transitions to the awaiting_manual_review state' do
      initialize_with_awaiting_manual_review_state
      stub_comment_post_req

      create_event_handler.process(event)

      state = load_state
      expect(state.state_name).to eq(Pulljoy::State::AWAITING_MANUAL_REVIEW)
    end

    it 'changes the review ID' do
      initialize_with_awaiting_manual_review_state
      stub_comment_post_req

      create_event_handler.process(event)

      state = load_state
      expect(state.review_id).not_to eq(first_review_id)
    end
  end

  describe 'upon receiving a new issue comment' do
    def initialize_with_awaiting_manual_review_state
      save_state(
        repo_full_name: event.repository.full_name,
        pr_num: event.issue.number,
        state_name: Pulljoy::State::AWAITING_MANUAL_REVIEW,
        review_id: first_review_id,
      )
    end

    def stub_collaborator_permission_req(permission_level)
      stub_request(
        :get,
        "https://api.github.com/repos/#{event.repository.full_name}" \
          "/collaborators/#{event.comment.user.login}/permission"
      ).to_return(
        status: 200,
        headers: { 'Content-Type': 'application/json' },
        body: JSON.generate(
          permission: permission_level
        )
      )
    end

    def stub_comment_post_req
      stub_request(
        :post,
        "https://api.github.com/repos/#{event.repository.full_name}/issues/#{event.issue.number}/comments"
      ).to_return(status: 200)
    end

    def load_state
      @state_store.load(event.repository.full_name, event.issue.number)
    end

    def assert_still_in_awaiting_manual_review_state
      state = load_state
      expect(state.state_name).to eq(Pulljoy::State::AWAITING_MANUAL_REVIEW)
      expect(state.review_id).to eq(first_review_id)
    end

    describe 'when the sender is Pulljoy' do
      let(:event) do
        Pulljoy::IssueCommentEvent.new(
          action: Pulljoy::IssueCommentEvent::ACTION_CREATED,
          repository: {
            full_name: 'test/test'
          },
          issue: {
            number: 123,
          },
          comment: {
            id: 456,
            body: 'hi',
            user: {
              login: my_username
            }
          }
        )
      end

      it 'ignores the message' do
        initialize_with_awaiting_manual_review_state
        create_event_handler.process(event)

        expect(@logio.string).to include('Ignoring comment by myself')
        assert_still_in_awaiting_manual_review_state
      end
    end

    describe 'when the sender does not have write access to the repo' do
      describe 'and the comment contains a command' do
        let(:event) do
          Pulljoy::IssueCommentEvent.new(
            action: Pulljoy::IssueCommentEvent::ACTION_CREATED,
            repository: {
              full_name: 'test/test'
            },
            issue: {
              number: 123,
            },
            comment: {
              id: 456,
              body: "#{Pulljoy::COMMAND_PREFIX} approve 123",
              user: {
                login: 'someone'
              }
            }
          )
        end

        it 'responds with a refusal' do
          permission_req = stub_collaborator_permission_req('read')
          comment_post_req = stub_comment_post_req.with(
            body: /Sorry @#{Regexp.escape event.comment.user.login}: You're not authorized/
          )

          initialize_with_awaiting_manual_review_state
          create_event_handler.process(event)

          expect(permission_req).to have_been_requested
          expect(comment_post_req).to have_been_requested
          assert_still_in_awaiting_manual_review_state
        end
      end

      describe 'and the comment contains no command' do
        let(:event) do
          Pulljoy::IssueCommentEvent.new(
            action: Pulljoy::IssueCommentEvent::ACTION_CREATED,
            repository: {
              full_name: 'test/test'
            },
            issue: {
              number: 123,
            },
            comment: {
              id: 456,
              body: 'hi',
              user: {
                login: 'someone'
              }
            }
          )
        end

        it 'ignores the message' do
          initialize_with_awaiting_manual_review_state
          create_event_handler.process(event)

          expect(@logio.string).to include('Ignoring comment: no command found')
          assert_still_in_awaiting_manual_review_state
        end
      end

      describe 'and the comment contains an invalid command' do
        let(:event) do
          Pulljoy::IssueCommentEvent.new(
            action: Pulljoy::IssueCommentEvent::ACTION_CREATED,
            repository: {
              full_name: 'test/test'
            },
            issue: {
              number: 123,
            },
            comment: {
              id: 456,
              body: "#{Pulljoy::COMMAND_PREFIX} foo",
              user: {
                login: 'someone'
              }
            }
          )
        end

        it 'ignores the message' do
          permission_req = stub_collaborator_permission_req('read')
          comment_post_req = stub_comment_post_req.with(
            body: /Sorry @#{Regexp.escape event.comment.user.login}: You're not authorized/
          )

          initialize_with_awaiting_manual_review_state
          create_event_handler.process(event)

          expect(permission_req).to have_been_requested
          expect(comment_post_req).to have_been_requested
          assert_still_in_awaiting_manual_review_state
        end
      end
    end

    describe 'when the comment contains no Pulljoy command' do
      let(:event) do
        Pulljoy::IssueCommentEvent.new(
          action: Pulljoy::IssueCommentEvent::ACTION_CREATED,
          repository: {
            full_name: 'test/test'
          },
          issue: {
            number: 123,
          },
          comment: {
            id: 456,
            body: 'hi',
            user: {
              login: 'someone'
            }
          }
        )
      end

      it 'ignores the message' do
        stub_collaborator_permission_req('write')
        initialize_with_awaiting_manual_review_state
        create_event_handler.process(event)

        expect(@logio.string).to include('Ignoring comment: no command found in comment')
        assert_still_in_awaiting_manual_review_state
      end
    end

    describe 'when the comment contains an unsupported command' do
      let(:event) do
        Pulljoy::IssueCommentEvent.new(
          action: Pulljoy::IssueCommentEvent::ACTION_CREATED,
          repository: {
            full_name: 'test/test'
          },
          issue: {
            number: 123,
          },
          comment: {
            id: 456,
            body: "#{Pulljoy::COMMAND_PREFIX} foo",
            user: {
              login: 'someone'
            }
          }
        )
      end

      it 'responds with an error message' do
        stub_collaborator_permission_req('write')
        comment_post_req = stub_comment_post_req.with(
          body: /Sorry @#{Regexp.escape event.comment.user.login}: Unsupported command type \\"foo\\"/
        )

        initialize_with_awaiting_manual_review_state
        create_event_handler.process(event)

        expect(comment_post_req).to have_been_requested
      end

      it 'does not change state' do
        stub_collaborator_permission_req('write')
        stub_comment_post_req

        initialize_with_awaiting_manual_review_state
        create_event_handler.process(event)

        assert_still_in_awaiting_manual_review_state
      end
    end

    describe 'when the comment contains a command with invalid syntax' do
      let(:event) do
        Pulljoy::IssueCommentEvent.new(
          action: Pulljoy::IssueCommentEvent::ACTION_CREATED,
          repository: {
            full_name: 'test/test'
          },
          issue: {
            number: 123,
          },
          comment: {
            id: 456,
            body: "#{Pulljoy::COMMAND_PREFIX} approve",
            user: {
              login: 'someone'
            }
          }
        )
      end

      it 'responds with an error message' do
        stub_collaborator_permission_req('write')
        comment_post_req = stub_comment_post_req.with(
          body: /Sorry @#{Regexp.escape event.comment.user.login}: 'approve' command requires exactly 1 argument/
        )

        initialize_with_awaiting_manual_review_state
        create_event_handler.process(event)

        expect(comment_post_req).to have_been_requested
      end

      it 'does not change state' do
        stub_collaborator_permission_req('write')
        stub_comment_post_req

        initialize_with_awaiting_manual_review_state
        create_event_handler.process(event)

        assert_still_in_awaiting_manual_review_state
      end
    end

    describe 'when the comment contains a review request approval command' do
      let(:event) do
        Pulljoy::IssueCommentEvent.new(
          action: Pulljoy::IssueCommentEvent::ACTION_CREATED,
          repository: {
            full_name: 'test/test'
          },
          issue: {
            number: 123,
          },
          comment: {
            id: 456,
            body: "#{Pulljoy::COMMAND_PREFIX} approve #{first_review_id}",
            user: {
              login: 'someone'
            }
          }
        )
      end

      describe 'when not in the awaiting_manual_review state' do
        before :each do
          save_state(
            repo_full_name: event.repository.full_name,
            pr_num: event.issue.number,
            state_name: Pulljoy::State::STANDING_BY,
            commit_sha: 'head',
          )
        end

        it 'refuses the command' do
          stub_collaborator_permission_req('write')
          comment_post_req = stub_comment_post_req.with(
            body: /Sorry .*?, there's no review request awaiting approval/
          )

          create_event_handler.process(event)

          expect(comment_post_req).to have_been_requested
          expect(load_state.state_name).to eq(Pulljoy::State::STANDING_BY)
        end
      end

      describe 'when no state is available for the current pull request' do
        it 'refuses the command' do
          stub_collaborator_permission_req('write')
          comment_post_req = stub_comment_post_req.with(
            body: /Sorry .*?, there's no review request awaiting approval/
          )

          create_event_handler.process(event)

          expect(comment_post_req).to have_been_requested
          expect(load_state).to be_nil
        end
      end

      describe 'when the wrong review ID is given' do
        before :each do
          save_state(
            repo_full_name: event.repository.full_name,
            pr_num: event.issue.number,
            state_name: Pulljoy::State::AWAITING_MANUAL_REVIEW,
            review_id: "not #{first_review_id}",
          )
        end

        it 'tells the sender that the ID is wrong' do
          stub_collaborator_permission_req('write')
          comment_post_req = stub_comment_post_req.with(
            body: /that was the wrong review ID/
          )

          create_event_handler.process(event)

          expect(comment_post_req).to have_been_requested
        end

        it 'stays in the awaiting_manual_review state' do
          stub_collaborator_permission_req('write')
          stub_comment_post_req

          create_event_handler.process(event)

          state = load_state
          expect(state.state_name).to eq(Pulljoy::State::AWAITING_MANUAL_REVIEW)
          expect(state.review_id).to eq("not #{first_review_id}")
        end
      end

      describe 'when the right review ID is given' do
        def stub_pull_request_req
          stub_request(
            :get, "https://api.github.com/repos/#{event.repository.full_name}/pulls/#{event.issue.number}"
          ).to_return(
            status: 200,
            headers: { 'Content-Type' => 'application/json' },
            body: JSON.generate(
              number: event.issue.number,
              head: {
                sha: 'fork-commit',
                repo: {
                  full_name: 'fork/test'
                }
              },
              base: {
                sha: 'base-commit',
                repo: event.repository.to_hash
              }
            )
          )
        end

        it 'creates a local branch' do
          initialize_with_awaiting_manual_review_state
          stub_collaborator_permission_req('write')
          pull_request_req = stub_pull_request_req

          handler = create_event_handler
          expect(handler).to receive(:create_local_branch)
            .with('fork/test', 'test/test', 'fork-commit')
            .and_return([true, ''])
          handler.process(event)
          expect(pull_request_req).to have_been_requested
        end

        it 'transitions to the awaiting_ci state' do
          initialize_with_awaiting_manual_review_state
          stub_collaborator_permission_req('write')
          stub_pull_request_req

          handler = create_event_handler
          allow(handler).to receive(:create_local_branch).and_return([true, ''])
          handler.process(event)

          state = load_state
          expect(state.state_name).to eq(Pulljoy::State::AWAITING_CI)
          expect(state.commit_sha).to eq('fork-commit')
        end
      end
    end
  end

  describe 'upon CI run completion' do
    def load_state
      @state_store.load(
        event.repository.full_name,
        event.check_suite.pull_requests[0].number
      )
    end

    describe 'if the run is not for the latest pushed commit' do
      let(:event) do
        Pulljoy::CheckSuiteEvent.new(
          action: Pulljoy::CheckSuiteEvent::ACTION_COMPLETED,
          repository: {
            full_name: 'test/test'
          },
          check_suite: {
            head_sha: 'head',
            status: Pulljoy::CheckSuiteEvent::STATUS_COMPLETED,
            conclusion: Pulljoy::CheckSuiteEvent::CONCLUSION_SUCCESS,
            pull_requests: [
              {
                number: 123,
              }
            ]
          }
        )
      end

      before :each do
        save_state(
          repo_full_name: event.repository.full_name,
          pr_num: event.check_suite.pull_requests[0].number,
          state_name: Pulljoy::State::AWAITING_CI,
          commit_sha: 'latest',
        )
      end

      it 'ignores the event' do
        create_event_handler.process(event)

        expect(@logio.string).to match(
          /the commit for which the check suite was completed, is not the one we expect/
        )
        expect(load_state.state_name).to eq(Pulljoy::State::AWAITING_CI)
      end
    end

    describe 'if the run is not for a repo for which we have state' do
      let(:event) do
        Pulljoy::CheckSuiteEvent.new(
          action: Pulljoy::CheckSuiteEvent::ACTION_COMPLETED,
          repository: {
            full_name: 'test/test'
          },
          check_suite: {
            head_sha: 'head',
            status: Pulljoy::CheckSuiteEvent::STATUS_COMPLETED,
            conclusion: Pulljoy::CheckSuiteEvent::CONCLUSION_SUCCESS,
            pull_requests: [
              {
                number: 123,
              }
            ]
          }
        )
      end

      it 'ignores the event' do
        create_event_handler.process(event)

        expect(@logio.string).to match(
          /Ignoring PR because it's not known by Pulljoy/
        )
        expect(@state_store.count).to eq(0)
      end
    end

    describe 'if the run is not for a PR for which we have state' do
      let(:event) do
        Pulljoy::CheckSuiteEvent.new(
          action: Pulljoy::CheckSuiteEvent::ACTION_COMPLETED,
          repository: {
            full_name: 'test/test'
          },
          check_suite: {
            head_sha: 'head',
            status: Pulljoy::CheckSuiteEvent::STATUS_COMPLETED,
            conclusion: Pulljoy::CheckSuiteEvent::CONCLUSION_SUCCESS,
            pull_requests: [
              {
                number: 123,
              }
            ]
          }
        )
      end

      before :each do
        save_state(
          repo_full_name: event.repository.full_name,
          pr_num: 456,
          state_name: Pulljoy::State::AWAITING_CI,
          commit_sha: event.check_suite.head_sha,
        )
      end

      it 'ignores the event' do
        create_event_handler.process(event)

        expect(@logio.string).to match(
          /Ignoring PR because it's not known by Pulljoy/
        )
        expect(@state_store.count).to eq(1)

        state = @state_store.first
        expect(state.state_name).to eq(Pulljoy::State::AWAITING_CI)
      end
    end

    describe 'if not all check suites for the commit are completed' do
      let(:event) do
        Pulljoy::CheckSuiteEvent.new(
          action: Pulljoy::CheckSuiteEvent::ACTION_COMPLETED,
          repository: {
            full_name: 'test/test'
          },
          check_suite: {
            head_sha: 'head',
            status: Pulljoy::CheckSuiteEvent::STATUS_COMPLETED,
            conclusion: Pulljoy::CheckSuiteEvent::CONCLUSION_SUCCESS,
            pull_requests: [
              {
                number: 123,
              }
            ]
          }
        )
      end

      before :each do
        save_state(
          repo_full_name: event.repository.full_name,
          pr_num: event.check_suite.pull_requests[0].number,
          state_name: Pulljoy::State::AWAITING_CI,
          commit_sha: event.check_suite.head_sha,
        )
      end

      def stub_check_suites_for_ref
        stub_request(
          :get,
          "https://api.github.com/repos/#{event.repository.full_name}" \
            "/commits/#{event.check_suite.head_sha}/check-suites"
        ).to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(
            total_count: 1,
            check_suites: [
              {
                status: 'in_progress'
              }
            ]
          )
        )
      end

      it 'ignores the event' do
        check_suites_for_ref_req = stub_check_suites_for_ref

        create_event_handler.process(event)

        expect(@logio.string).to match(
          /Ignoring PR because not all check suites for this commit are completed/
        )
        expect(@state_store.count).to eq(1)

        state = @state_store.first
        expect(state.state_name).to eq(Pulljoy::State::AWAITING_CI)

        expect(check_suites_for_ref_req).to have_been_requested
      end
    end

    describe 'if we are in the awaiting_manual_review state' do
      let(:event) do
        Pulljoy::CheckSuiteEvent.new(
          action: Pulljoy::CheckSuiteEvent::ACTION_COMPLETED,
          repository: {
            full_name: 'test/test'
          },
          check_suite: {
            head_sha: 'head',
            status: Pulljoy::CheckSuiteEvent::STATUS_COMPLETED,
            conclusion: Pulljoy::CheckSuiteEvent::CONCLUSION_SUCCESS,
            pull_requests: [
              {
                number: 123,
              }
            ]
          }
        )
      end

      before :each do
        save_state(
          repo_full_name: event.repository.full_name,
          pr_num: event.check_suite.pull_requests[0].number,
          state_name: Pulljoy::State::AWAITING_MANUAL_REVIEW,
          review_id: first_review_id,
        )
      end

      it 'ignores the event' do
        create_event_handler.process(event)

        expect(@logio.string).to match(
          /Ignoring PR because state is not #{Regexp.escape Pulljoy::State::AWAITING_CI}/
        )
        expect(load_state.state_name).to eq(Pulljoy::State::AWAITING_MANUAL_REVIEW)
      end
    end

    describe 'if we are in the standing_by state' do
      let(:event) do
        Pulljoy::CheckSuiteEvent.new(
          action: Pulljoy::CheckSuiteEvent::ACTION_COMPLETED,
          repository: {
            full_name: 'test/test'
          },
          check_suite: {
            head_sha: 'head',
            status: Pulljoy::CheckSuiteEvent::STATUS_COMPLETED,
            conclusion: Pulljoy::CheckSuiteEvent::CONCLUSION_SUCCESS,
            pull_requests: [
              {
                number: 123,
              }
            ]
          }
        )
      end

      before :each do
        save_state(
          repo_full_name: event.repository.full_name,
          pr_num: event.check_suite.pull_requests[0].number,
          state_name: Pulljoy::State::STANDING_BY,
          commit_sha: event.check_suite.head_sha,
        )
      end

      def stub_comment_post_req
        stub_request(
          :post,
          "https://api.github.com/repos/#{event.repository.full_name}" \
            "/issues/#{event.check_suite.pull_requests[0].number}/comments"
        ).to_return(status: 200)
      end

      def stub_check_suites_for_ref
        stub_request(
          :get,
          "https://api.github.com/repos/#{event.repository.full_name}" \
            "/commits/#{event.check_suite.head_sha}/check-suites"
        ).to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(
            total_count: 1,
            check_suites: [
              {
                status: 'completed'
              }
            ]
          )
        )
      end

      def stub_check_runs_for_ref # rubocop:disable Metrics/MethodLength
        stub_request(
          :get,
          "https://api.github.com/repos/#{event.repository.full_name}" \
            "/commits/#{event.check_suite.head_sha}/check-runs"
        ).to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(
            total_count: 1,
            check_runs: [
              {
                conclusion: 'success',
                html_url: 'http://check-run',
                app: {
                  name: 'Github Actions',
                },
                output: {
                  title: 'CI complete',
                }
              }
            ]
          )
        )
      end

      it 're-reports the result' do
        check_suites_for_ref_req = stub_check_suites_for_ref
        check_runs_for_ref_req = stub_check_runs_for_ref
        comment_post_req = stub_comment_post_req.with(
          body: /CI run for #{Regexp.escape event.check_suite.head_sha} complete/
        )

        handler = create_event_handler
        allow(handler).to receive(:delete_local_branch)

        handler.process(event)

        expect(check_suites_for_ref_req).to have_been_requested
        expect(check_runs_for_ref_req).to have_been_requested
        expect(comment_post_req).to have_been_requested
      end

      it 'remains in the standing_by state' do
        stub_check_suites_for_ref
        stub_check_runs_for_ref
        stub_comment_post_req

        handler = create_event_handler
        allow(handler).to receive(:delete_local_branch)

        handler.process(event)

        expect(load_state.state_name).to eq(Pulljoy::State::STANDING_BY)
      end
    end

    describe 'if we are in the awaiting_ci state' do
      let(:event) do
        Pulljoy::CheckSuiteEvent.new(
          action: Pulljoy::CheckSuiteEvent::ACTION_COMPLETED,
          repository: {
            full_name: 'test/test'
          },
          check_suite: {
            head_sha: 'head',
            status: Pulljoy::CheckSuiteEvent::STATUS_COMPLETED,
            conclusion: Pulljoy::CheckSuiteEvent::CONCLUSION_SUCCESS,
            pull_requests: [
              {
                number: 123,
              }
            ]
          }
        )
      end

      before :each do
        save_state(
          repo_full_name: event.repository.full_name,
          pr_num: event.check_suite.pull_requests[0].number,
          state_name: Pulljoy::State::AWAITING_CI,
          commit_sha: event.check_suite.head_sha,
        )
      end

      def stub_comment_post_req
        stub_request(
          :post,
          "https://api.github.com/repos/#{event.repository.full_name}" \
            "/issues/#{event.check_suite.pull_requests[0].number}/comments"
        ).to_return(status: 200)
      end

      def stub_check_suites_for_ref
        stub_request(
          :get,
          "https://api.github.com/repos/#{event.repository.full_name}" \
            "/commits/#{event.check_suite.head_sha}/check-suites"
        ).to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(
            total_count: 1,
            check_suites: [
              {
                status: 'completed'
              }
            ]
          )
        )
      end

      def stub_check_runs_for_ref # rubocop:disable Metrics/MethodLength
        stub_request(
          :get,
          "https://api.github.com/repos/#{event.repository.full_name}" \
            "/commits/#{event.check_suite.head_sha}/check-runs"
        ).to_return(
          status: 200,
          headers: { 'Content-Type' => 'application/json' },
          body: JSON.generate(
            total_count: 1,
            check_runs: [
              {
                conclusion: 'success',
                html_url: 'http://check-run',
                app: {
                  name: 'Github Actions',
                },
                output: {
                  title: 'CI complete',
                }
              }
            ]
          )
        )
      end

      it 'reports the result' do
        check_suites_for_ref_req = stub_check_suites_for_ref
        check_runs_for_ref_req = stub_check_runs_for_ref
        comment_post_req = stub_comment_post_req.with(
          body: /CI run for #{Regexp.escape event.check_suite.head_sha} complete/
        )

        handler = create_event_handler
        allow(handler).to receive(:delete_local_branch)

        handler.process(event)

        expect(check_suites_for_ref_req).to have_been_requested
        expect(check_runs_for_ref_req).to have_been_requested
        expect(comment_post_req).to have_been_requested
      end

      it 'transitions to the standing_by state' do
        stub_check_suites_for_ref
        stub_check_runs_for_ref
        stub_comment_post_req

        handler = create_event_handler
        allow(handler).to receive(:delete_local_branch)

        handler.process(event)

        expect(load_state.state_name).to eq(Pulljoy::State::STANDING_BY)
      end

      it 'deletes the local branch' do
        stub_check_suites_for_ref
        stub_check_runs_for_ref
        stub_comment_post_req

        handler = create_event_handler
        expect(handler).to receive(:delete_local_branch).with(event.repository.full_name)

        handler.process(event)
      end
    end
  end

  describe 'when deleting a local branch' do
    it 'does nothing when the branch does not exist' do
      delete_ref_req = stub_request(
        :delete,
        'https://api.github.com/repos/foo/foo/git/refs/heads/pulljoy/123'
      ).to_return(
        status: 422,
        headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(
          message: 'Reference does not exist'
        )
      )

      handler = create_event_handler
      expect(handler).to receive(:local_branch_name).at_least(:once).and_return('pulljoy/123')
      handler.send(:delete_local_branch, 'foo/foo')

      expect(delete_ref_req).to have_been_requested
    end

    it 'raises the API error if the error is not related to the branch not existing' do
      delete_ref_req = stub_request(
        :delete,
        'https://api.github.com/repos/foo/foo/git/refs/heads/pulljoy/123'
      ).to_return(
        status: 422,
        headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(
          message: 'Something went wrong'
        )
      )

      handler = create_event_handler
      expect(handler).to receive(:local_branch_name).at_least(:once).and_return('pulljoy/123')
      expect { handler.send(:delete_local_branch, 'foo/foo') }.to \
        raise_error(Octokit::UnprocessableEntity, /Something went wrong/)

      expect(delete_ref_req).to have_been_requested
    end
  end

  describe 'when cancelling a CI run' do
    before :each do
      save_state(
        repo_full_name: close_pr_event.repository.full_name,
        pr_num: close_pr_event.pull_request.number,
        state_name: Pulljoy::State::AWAITING_CI,
        commit_sha: local_branch_sha,
      )
    end

    let(:close_pr_event) do
      Pulljoy::PullRequestEvent.new(
        action: Pulljoy::PullRequestEvent::ACTION_CLOSED,
        repository: {
          full_name: 'test/test'
        },
        user: {
          login: 'pulljoy'
        },
        pull_request: {
          number: 123,
          head: {
            sha: 'head',
            repo: {
              full_name: 'fork/test',
            }
          },
          base: {
            sha: 'base',
            repo: {
              full_name: 'test/test'
            }
          }
        }
      )
    end

    let(:local_branch_sha) { 'local' }

    def stub_query_runs_req(status, result_workflow_run_id, result_commit_sha)
      stub_request(
        :get,
        "https://api.github.com/repos/#{close_pr_event.repository.full_name}/actions/runs?status=#{status}"
      ).to_return(
        status: 200,
        headers: { 'Content-Type' => 'application/json' },
        body: JSON.generate(
          total_count: 1,
          workflow_runs: [
            {
              id: result_workflow_run_id,
              head_sha: result_commit_sha
            }
          ]
        )
      )
    end

    def stub_cancel_run_req(workflow_run_id)
      stub_request(
        :post,
        "https://api.github.com/repos/#{close_pr_event.repository.full_name}" \
          "/actions/runs/#{workflow_run_id}/cancel"
      ).to_return(status: 200)
    end

    def stub_delete_branch_req
      stub_request(
        :delete,
        "https://api.github.com/repos/#{close_pr_event.repository.full_name}" \
          "/git/refs/heads/pulljoy/#{close_pr_event.pull_request.number}"
      ).to_return(status: 200)
    end

    it 'finds the run in the run in queued workflow runs' do
      query_runs_req = stub_query_runs_req(:queued, 123, local_branch_sha)
      stub_cancel_run_req(123)
      stub_delete_branch_req

      create_event_handler.process(close_pr_event)

      expect(query_runs_req).to have_been_requested
    end

    it 'finds the run in the run in in-progress workflow runs' do
      query_runs_req1 = stub_query_runs_req(:queued, 123, "not #{local_branch_sha}")
      query_runs_req2 = stub_query_runs_req(:in_progress, 124, local_branch_sha)
      stub_cancel_run_req(124)
      stub_delete_branch_req

      create_event_handler.process(close_pr_event)

      expect(query_runs_req1).to have_been_requested
      expect(query_runs_req2).to have_been_requested
    end

    it 'cancels nothing when there is no CI run' do
      query_runs_req1 = stub_query_runs_req(:queued, 123, "not #{local_branch_sha}")
      query_runs_req2 = stub_query_runs_req(:in_progress, 124, "still not #{local_branch_sha}")
      stub_delete_branch_req

      create_event_handler.process(close_pr_event)

      expect(query_runs_req1).to have_been_requested
      expect(query_runs_req2).to have_been_requested
    end
  end
end
