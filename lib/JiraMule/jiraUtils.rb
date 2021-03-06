require 'uri'
require 'net/http'
require 'net/http/post/multipart'
require 'json'
require 'yaml'
require 'date'
require 'pp'
require 'mime/types'
require 'JiraMule/Config'
require 'JiraMule/Passwords'
require 'JiraMule/http'
require 'JiraMule/verbosing'

module JiraMule
    class JiraUtilsException < Exception
        attr_accessor :request, :response
    end

    class JiraUtils
        include Verbose
        include Http

        # TODO: all params are now optional.
        def initialize(args=nil, options=nil, cfg=nil)
            acc = Account.new
            up = acc.loginInfo
            @username = up[:email]
            @password = up[:password]
        end
        attr_reader :username, :password

        def jiraEndPoint
            endPoint()
        end

        def endPoint(path='')
          URI($cfg['net.url'] + '/rest/api/2/' + path.to_s)
        end

        def project
            return @project unless @project.nil?
            @project = $cfg['jira.project']
            return @project
        end

        ##
        # Given an array of issues keys that may or may not have the project prefixed
        # Return an array with the project prefixed.
        #
        # So on project APP, from %w{1 56 BUG-78} you get %w{APP-1 APP-56 BUG-78}
        def expandKeys(keys)
            return keys.map do |k|
                k.match(/([a-zA-Z0-9]+-)?(\d+)/) do |m|
                    if m[1].nil? then
                        "#{project}-#{m[2]}"
                    else
                        m[0]
                    end
                end
            end.compact
        end

        ##
        # Allow for some sloppy matching.
        # +transition+:: The transition hash to match against
        # +couldBe+:: The string from a human to match for
        def fuzzyMatchStatus(transition, couldBe)
            return transition[:id] == couldBe if couldBe =~ /^\d+$/

            # Build a regexp for all sorts of variations.

            # Replace whitespace with a rex for dashes, whitespace, or nospace.
            cb = couldBe.gsub(/\s+/, '[-_\s]*')

            matcher = Regexp.new(cb, Regexp::IGNORECASE)
            debug "Fuzzing: #{transition[:name]} =~ #{cb}"
            return transition[:name] =~ matcher
        end

        ##
        # Lookup a path from one state to another in a map
        # +at+:: The starting state
        # +to+:: The stopping state
        def getPath(at, to)
            verbose "Getting path from '#{at}' to '#{to}'"

            # [goto-map]
            # at-to: each, step, to, end
            tr = $cfg["goto-maps.#{at.gsub(/\W+/,'_')}-#{to.gsub(/\W+/,'_')}"]
            (tr or "").split(/,/).map{|p| p.strip}
        end

        ##
        # Run a JQL query and get issues with the selected fields
        def getIssues(query, fields=[ 'key', 'summary' ])
            verbose "Get keys: #{query}"
            data = post('search', {:jql=>query, :fields=>fields})
            return data[:issues] if data.kind_of?(Hash) and data.has_key?(:issues)
            []
        end

        ##
        # make sure #user is an actual user in the system.
        def checkUser(user, keyMatch=true)
            verbose "Get user: #{user}"
            users = get("user/search", {:username=>user})
            return [] if users.empty?
            userKeys = users.map{|i| i[:key]}
            return [user] if keyMatch and userKeys.index(user)
            return userKeys
        end

        ##
        # Create a new version for release.
        # TODO: test this.
        def createVersion(project, version)
            verbose "Creating #{version} in #{project}"
            unless $cfg['tool.dry'] then
                data = post('version', {
                    'name' => version,
                    'archived' => false,
                    'released' => true,
                    'releaseDate' => DateTime.now.strftime('%Y-%m-%d'),
                    'project' => project,
                })
                unless data[:released] then
                    # Sometimes setting released on create doesn't work.
                    # So modify it.
                    put("version/#{data[:id]}", {:released=>true})
                end
            end
        end

        ##
        # Create a new issue
        # +type+:: The type of issue this is
        # +summary+:: Short title text
        # +description+:: Full details.
        def createIssue(type, summary, description)
            verbose "Creating #{type} issue for #{summary}"

            customfields = {}
            cust = $cfg['customfields.create']
            customfields = YAML.load(cust, 'cfg->customfields.create') unless cust.nil?
            verbose " With custom fields: #{cust.to_json}" unless cust.nil?

            unless $cfg['tool.dry'] then
                post('issue', {
                    :fields=>customfields.merge({
                        :issuetype=>{:name=>type},
                        :project=>{:key=>project},
                        :summary=>summary,
                        :description=>description,
                        :labels=>['auto-imported'],
                    })
                })
            else
                {:key=>'_'}
            end
        end

        ##
        # Check this issue type in current project
        def checkIssueType(type='bug')
            rt = Regexp.new(type.gsub(/\s+/, '[-_\s]*'), Regexp::IGNORECASE)
            cmeta = get("issue/createmeta?projectKeys=#{project}")
            prj = cmeta[:projects].select{|p| p[:key] == project}.first
            prj[:issuetypes].select{|it| it[:name] =~ rt}
        end

        # Update fields on a key
        # +keys+:: Array of keys to update
        # +update+:: Hash of fields to update. (see https://docs.atlassian.com/jira/REST/6.4.7/#d2e261)
        def updateKeys(keys, update)
            keys = [keys] unless keys.kind_of? Array
            keys.each do |key|
                verbose "Updating key #{key} with #{update}"
                put("issue/#{key}", {:update=>update}) unless $cfg['tool.dry']
            end
        end

        # Transition key into a new status
        # +key+:: The key to transition
        # +toID+:: The ID of the transition to make
        def transition(key, toID)
            verbose "Transitioning key #{key} to #{toID}"
            post('issue/' + key + '/transitions', {:transition=>{:id=>toID}}) unless $cfg['tool.dry']
        end

        # Get the transitions that a key can move to.
        # +key+:: The issue
        def transitionsFor(key)
            verbose "Fetching transitions for #{key}"
            data = get('issue/' + key + '/transitions')
            data[:transitions]
        end

        # Get the status for a project
        # +project+:: The project to fetch status from
        def statusesFor(prj=nil)
            prj = project if prj.nil?
            verbose "Fetching statuses for #{prj}"
            get('project/' + prj + '/statuses')
        end

        # Assign issues to a user
        # +keys+:: Array of keys to assign
        # +to+:: The user to assign to (or -1 for default)
        def assignTo(keys, to="-1")
            keys = [keys] unless keys.kind_of? Array
            r=[]
            keys.each do |key|
                verbose "Assigning #{key} to #{to}"
                r << put("issue/#{key}/assignee", {:name=>to}) unless $cfg['tool.dry']
            end
            r
        end

        # Log a work entry to Jira
        # +key+:: The issue to log work on
        # +timespend+:: The time spent in seconds
        # +notes+:: Any notes to add.
        # +on+:: When this work happened. (default is now)
        def logWork(key, timespent, notes="", on=nil)
            body = {
                :comment => notes,
                :timeSpentSeconds => timespent,
            }
            body[:started] = on.to_time.strftime('%FT%T.%3N%z') unless on.nil?

            verbose "Logging #{timespent} of work on #{body[:started] or 'now'} to #{key} with note \"#{notes}\""
            post('issue/' + key + '/worklog', body) unless $cfg['tool.dry']
        end

        # Get the work log for an Issue
        # +key+:: The issue to retrive the work log for
        def workLogs(key)
            verbose "Fetching work logs for #{key}"
            get('issue/' + key + '/worklog')
        end

        ## Get links on an issue
        # +key+:: The issue to retrive the remote links for
        def remote_links(key)
            get("issue/#{key}/remotelink")
        end

        ## Attach a URL to an issue
        # +key+:: The issue to set a remote link on
        # +url+:: The URL to link to
        # +title+:: The title of the link
        def linkTo(key, url, title)
            verbose "Attaching [#{title}](#{url}) to #{key}"
            unless $cfg['tool.dry'] then
                post("issue/#{key}/remotelink", {
                    :object=>{
                        :url=>url,
                        :title=>title,
                    }
                })
            # XXX Lookup favicon for site and include?
            end
        end

        def linkKeys(key, toKey, relation='related to')
        end

        # Attach a file to an issue.
        # +key+:: The issue to attach to
        # +file+:: Full path to the file to be attached
        # +type+:: MIME type of the fiel data
        # +name+:: Aternate name of file being uploaded
        def attach(key, file, type=nil, name=nil)
            file = Pathname.new(file) unless file.kind_of? Pathname

            name = file.basename if name.nil?

            if type.nil? then
                mime = MIME::Types.type_for(file.to_s)[0] || MIME::Types["application/octet-stream"][0]
                type = mime.simplified
            end

            verbose "Going to upload #{file} [#{type}] to #{key}"

            uri = endPoint('issue/' + key + '/attachments')
            fuio = UploadIO.new(file.open, type, name)
            req = Net::HTTP::Post::Multipart.new(uri, 'file'=> fuio )
            req.basic_auth(username(), password())
            req['User-Agent'] = "JiraMule/#{JiraMule::VERSION}"
            #set_def_headers(req)
            req['X-Atlassian-Token'] = 'nocheck'
            workit(req) unless $cfg['tool.dry']
        end

    end
end
#  vim: set sw=4 ts=4 :
