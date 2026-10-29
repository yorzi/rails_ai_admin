# Third-party notices

Original project code is MIT licensed. No competitor source or assets are copied.
Runtime dependencies retain their own notices in their distributed packages:

| Dependency | License | Source |
| --- | --- | --- |
| Rails | MIT | https://github.com/rails/rails |
| rails_tool_views | MIT | https://github.com/yorzi/rails_tool_views |
| RubyLLM | MIT | https://github.com/crmne/ruby_llm |
| Turbo / turbo-rails | MIT | https://github.com/hotwired/turbo-rails |
| Stimulus / stimulus-rails | MIT | https://github.com/hotwired/stimulus-rails |

The prebuilt ESM contains Turbo 8.0.23 and Stimulus 3.2.2. Their complete notices
ship in `app/assets/builds/rails_ai_admin.LICENSE.txt`, generated from the sources
recorded in `frontend/licenses/README.md`. The host needs no Node build for these
assets. Dependency installation and license declarations do not prove a security
audit or grant rights to third-party trademarks.
