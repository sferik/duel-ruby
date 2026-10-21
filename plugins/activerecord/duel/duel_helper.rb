# frozen_string_literal: true

# The plugin guards its own speed: above all its subscriber, which runs
# for every query a user's benchmark makes, and what it does around
# every sample (reading its totals, and explaining its queries). Each
# version's plugin is the library Duel loads (duel/activerecord), and
# .duel.rb doesn't use it, so the Duel measuring is the same for both.
require "active_record"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")
ActiveRecord::Schema.verbose = false
ActiveRecord::Schema.define do
  create_table(:posts) { |t| t.string :title }
  create_table(:comments) { |t| t.references :post }
end

class Post < ActiveRecord::Base
  has_many :comments
end

class Comment < ActiveRecord::Base
  belongs_to :post
end

10.times { |i| Post.create!(title: "post #{i}").comments.create!([{}, {}, {}]) }

SQL = "sql.active_record"
TRANSACTION = "transaction.active_record"
INSTANTIATION = "instantiation.active_record"

# The payloads of the +event+ notifications the block makes, as Active
# Record sends them (it fails if there are none: what a benchmark replays
# must be there).
def captured(event = SQL, &)
  sent = []
  subscription = ActiveSupport::Notifications.subscribe(event) { |*, payload| sent << payload }
  begin
    yield
  ensure
    ActiveSupport::Notifications.unsubscribe(subscription)
  end
  sent.empty? ? raise("no queries to replay") : sent
end

# Queries the plugin counts: loads, a count, an insert (rolled back).
QUERIES = captured do
  Post.first.comments.to_a
  Post.includes(:comments).to_a
  Post.count
  Post.where(title: "post 1").to_a
  Post.transaction do
    Post.create!(title: "new")
    raise ActiveRecord::Rollback
  end
end.reject { |payload| payload[:name] == "TRANSACTION" }.freeze

# Queries it leaves out: schema queries, transactions' own statements,
# and those the query cache answered.
SKIPPED = [
  *captured { Post.connection.columns("posts") },
  *captured { Post.transaction { Post.count } }.select { |payload| payload[:name] == "TRANSACTION" },
  *captured { Post.cache { 2.times { Post.where(title: "post 1").to_a } } }.select { |payload| payload[:cached] }
].freeze

# A transaction, and the records a query instantiated.
TRANSACTIONS = captured(TRANSACTION) { Post.transaction { Post.count } }.freeze
INSTANTIATIONS = captured(INSTANTIATION) { Post.includes(:comments).first(3) }.freeze

# +count+ of +payloads+, in turn.
def replayed(payloads, count = 100) = payloads.cycle.first(count).freeze

# Sends +counter+ each of +payloads+ of +event+, as Active Support does
# (see Duel::ActiveRecord::Counter#start).
def notify(counter, payloads, event = SQL)
  payloads.each do |payload|
    counter.start(event, nil, payload)
    counter.finish(event, nil, payload)
  end
end

# Sends +counter+ more queries than it keeps track of (Counter::KEPT), so
# that what it keeps has stopped growing.
def warm(counter, payloads) = notify(counter, replayed(payloads, 2_000))

# A query's payload, as Active Record sends it, of +sql+.
def query_payload(sql) = QUERIES.first.merge(sql:).freeze

# The plugin as a worker has it, with +options+ (see
# Duel::ActiveRecord.configure): subscribed to what its measures need,
# until #unsubscribe (in each file's teardown). (A version from before
# c.use names it install.)
def subscribed(**options)
  config = Duel::Config.new
  plugin = Duel::ActiveRecord
  counter = plugin.public_send(plugin.respond_to?(:configure) ? :configure : :install, config, **options)
  counter.subscribe(config.metrics.first.measures.keys)
  counter
end

# +count+ queries' payloads, of different statements: those of QUERIES,
# then more like them.
def statements(count)
  sent = QUERIES.uniq { |payload| payload[:sql] }
  more = Array.new([count - sent.size, 0].max) { |i| query_payload(%(SELECT "posts".* FROM "posts" WHERE "posts"."id" > ? LIMIT #{i + 1})) }
  (sent + more).first(count)
end

# One reading of the totals around a sample, as Duel gives the plugin's
# details: only the queries it had counted matter.
Reading = Struct.new(:queries) do
  def total(_name) = queries
end
