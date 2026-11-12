# frozen_string_literal: true

D = Steep::Diagnostic

target :lib do
  signature "sig"
  # Signatures of what Duel uses from gems without any (Fiddle, StackProf,
  # Rake) and from JRuby: only for checking Duel, so not in the gem.
  signature "steep"

  check "lib"

  library "digest", "erb", "etc", "fileutils", "json", "net-http", "open3", "openssl", "optparse", "pathname", "socket", "tempfile", "timeout", "tmpdir", "uri"

  configure_code_diagnostics(D::Ruby.strict)
end
