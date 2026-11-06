# frozen_string_literal: true

require_relative "test_helper"

# What the runner and a worker say to each other, over a socket.
class MessageTest < DuelTest
  cover "Duel::Message*"

  def test_sends_messages_in_turn_and_keeps_their_strings_encodings
    ours, theirs = UNIXSocket.pair
    name = "caf\xE9".dup.force_encoding(Encoding::ISO_8859_1)
    Duel::Message.write(ours, {"name" => name, "n" => 3, "ratio" => 1.5, "ok" => true, "none" => nil})
    Duel::Message.write(ours, ["second"])

    first = Duel::Message.read(theirs)

    assert_equal({"name" => name, "n" => 3, "ratio" => 1.5, "ok" => true, "none" => nil}, first)
    assert_equal Encoding::ISO_8859_1, first.fetch("name").encoding, "not UTF-8, which JSON can't carry"
    assert_equal ["second"], Duel::Message.read(theirs), "each message alone, however many are waiting"
  ensure
    ours&.close
    theirs&.close
  end

  def test_reads_nothing_once_the_other_end_has_closed
    ours, theirs = UNIXSocket.pair
    ours.close

    assert_nil Duel::Message.read(theirs)
  ensure
    theirs&.close
  end
end
