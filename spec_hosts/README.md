# Packaged consumers

`session_sqlite/` is an independent minimal Rails Host with native cookie-session
authentication, BCrypt, a custom policy, Propshaft and a separate importmap.
It is copied to ignored `tmp/`, then consumes the built gem through RubyGems
installation. It never uses a repository path dependency or the dummy app.

Run `bundle exec rake build`, then `bundle exec ruby script/packaged_smoke.rb`.
The test data, login credentials and secret key are synthetic fixtures only.
Do not deploy this host. The script starts no server and calls no provider.

The planned Devise/Pundit/PostgreSQL second Host and legacy-admin migration Host
remain required. Reconfiguring this fixture does not count as another Host.
