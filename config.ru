# frozen_string_literal: true

require './lib/boot'
require './lib/factory'
require './lib/web_app'

config_source = Pulljoy::Boot.infer_config_source!
config = Pulljoy::Boot.load_config!(config_source)
logger = Pulljoy::Boot.create_logger(config)
octokit = Pulljoy::Boot.create_octokit(config)
state_store = Pulljoy::Boot.create_state_store(config)

Pulljoy::WebApp.set :environment, ENV['RACK_ENV']
Pulljoy::WebApp.activate_pulljoy_config(config)

run Pulljoy::WebApp.new(
  event_handler_factory: Pulljoy::Factory.new(
    my_github_username: Pulljoy::Boot.infer_github_username(octokit),
    octokit: octokit,
    logger: logger,
    state_store: state_store,
  ),
  logger: logger,
  state_store: state_store,
)
