require 'vine'

command :goto do |c|
  c.syntax = 'jm goto [options] [status] [key]'
  c.summary = 'Move issue to a status; making multiple transitions if needed'
  c.description = %{
	Named for the bad command that sometime there is nothing better to use.

	Your issue has a status X, and you need it in Y, and there are multiple steps from
	X to Y.  Why would you do something a computer can do better?  Hence goto.

	The down side is there is no good way to automatically get mutli-step transitions.
	So these need to be added to your config.
	}
  c.example 'Move BUG-4 into the In Progress state.', %{jm move 'In Progress' BUG-4}
  c.action do |args, options|
		jira = JiraUtils.new(args, options)
		to = args.shift

		# keys can be with or without the project prefix.
		keys = jira.expandKeys(args)
		printVars(:to=>to, :k=>keys)
		return if keys.empty?

		keys.each do |key|
			# First see if we can just go there.
			trans = jira.transitionsFor(key)
			direct = trans.select {|item| item['name'] == to || item['id'] == to }
			if not direct.empty? then
				# We can just go right there.
				id = direct.first['id']
				jira.transition(key, id)
				# TODO: deal with required field.
			else

				# where we are.
				query = "assignee = #{jira.username} AND project = #{jira.project} AND "
				query << "key = #{key}"
				issues = jira.getIssues(query, ["status"])
				type = issues.first.access('fields.issuetype.name')
				at = issues.first.access('fields.status.name')

				# lookup a transition map
				transMap = $cfg[".jira.goto.#{type}.#{at}.#{to}"]
				transMap = $cfg[".jira.goto.*.#{at}.#{to}"] if transMap.nil?
				raise "No transition map for #{key} from #{at} to #{to}" if transMap.nil?

				# Now move thru
				transMap.each do |step|
					trans = jira.transitionsFor(key)
					direct = trans.select {|item| item['name'] == step || item['id'] == step }
					raise "Broken transition step on #{key} to #{step}" if direct.empty?
					id = direct.first['id']
					jira.transition(key, id)
					# TODO: deal with required field.
				end

			end
		end
	end
end

command :mapGoto do |c|
  c.syntax = 'jm mapGoto [options]'
  c.summary = 'Attempt to build a map '
  c.description = %{
	}
  c.action do |args, options|
		jira = JiraUtils.new(args, options)

		# Get all of the states that issues can be in.
		# Try to find an actual issue in each state, and load the next transitions from
		# it.
		#
		types = jira.statusesFor(jira.project)
		
		types.each do |type|
			statuses = type['statuses']
			next if statuses.nil?
			next if statuses.empty?
			puts "- #{type['name']}:"
			statuses.each do |status|
				puts "    #{status['name']}"
				query = %{project = #{jira.project} AND issuetype = "#{type['name']}" AND status = "#{status['name']}"}
				issues = jira.getIssues(query, ["key"])
				if issues.empty? then
					#?
				else
					key = issues.first['key']
					# get transisitons.
					trans = jira.transitionsFor(key)
					trans.each {|tr| puts "      -> #{tr['name']}"}
				end
			end
		end
	end
end

#  vim: set sw=2 ts=2 :

