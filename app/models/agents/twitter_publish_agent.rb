module Agents
  class TwitterPublishAgent < Agent
    include TwitterConcern

    can_dry_run!
    cannot_be_scheduled!

    description <<-MD
      The Twitter Publish Agent publishes tweets from the events it receives.

      #{twitter_dependencies_missing if dependencies_missing?}

      To be able to use this Agent you need to authenticate with Twitter in the [Services](/services) section first.

      You must also specify a `message` parameter, you can use [Liquid](https://github.com/huginn/huginn/wiki/Formatting-Events-using-Liquid) to format the message.

      Set `expected_update_period_in_days` to the maximum amount of time that you'd expect to pass between Events being created by this Agent.

      If `output_mode` is set to `merge`, the emitted Event will be merged into the original contents of the received Event.
    MD

    event_description <<-MD
      Events look like this:
        {
          "success": true,
          "published_tweet": "...",
          "tweet_id": ...,
          "tweet_id_str": "...",
          "agent_id": ...,
          "event_id": ...
        }

        {
          "success": false,
          "error": "...",
          "failed_tweet": "...",
          "agent_id": ...,
          "event_id": ...
        }

      Original event contents will be merged when `output_mode` is set to `merge`.
    MD

    def validate_options
      errors.add(:base, "expected_update_period_in_days is required") unless options['expected_update_period_in_days'].present?

      if options['output_mode'].present? && !options['output_mode'].to_s.include?('{') && !%[clean merge].include?(options['output_mode'].to_s)
        errors.add(:base, "if provided, output_mode must be 'clean' or 'merge'")
      end
    end

    def working?
      event_created_within?(interpolated['expected_update_period_in_days']) && most_recent_event && most_recent_event.payload['success'] == true && !recent_error_logs?
    end

    def default_options
      {
        'expected_update_period_in_days' => "10",
        'message' => "{{text}}",
        'output_mode' => 'clean'
      }
    end

    def receive(incoming_events)
      # if there are too many, dump a bunch to avoid getting rate limited
      if incoming_events.count > 20
        incoming_events = incoming_events.first(20)
      end
      incoming_events.each do |event|
        tweet_text = interpolated(event)['message']
        tweet_media = interpolated(event)['media_url']
        new_event = interpolated['output_mode'].to_s == 'merge' ? event.payload.dup : {}
        begin
          tweet = publish_tweet tweet_text, tweet_media
        rescue Twitter::Error => e
          new_event.update(
            'success' => false,
            'error' => e.message,
            'failed_tweet' => tweet_text,
            'agent_id' => event.agent_id,
            'event_id' => event.id
          )
        else
          new_event.update(
            'success' => true,
            'published_tweet' => tweet_text,
            'tweet_id' => tweet.id,
            'agent_id' => event.agent_id,
            'event_id' => event.id
          )
        end
        create_event payload: new_event
      end
    end

    def publish_tweet(text, media)
      return twitter.update_with_media(text, File.new(open(media))) unless media.blank?
      twitter.update(text)
    end
  end
end
