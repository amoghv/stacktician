
class Stack < ActiveRecord::Base
  attr_accessible :description, :reason, :stack_id, :stack_name, :status, :stack_template_id, :launched_at, :stack_parameters_attributes, :ruote_wfid
  belongs_to :user
  belongs_to :stack_template
  has_many :stack_resources, :dependent => :destroy
  has_many :stack_parameters, :dependent => :destroy
  has_many :stack_outputs, :dependent => :destroy
  accepts_nested_attributes_for :stack_parameters, :reject_if => lambda { |p| p[:param_value].blank? }
  #accepts_nested_attributes_for :stack_parameters

  before_save :create_stack_id

  validates :stack_name, presence: true,  length: { maximum: 50 }, uniqueness: true
  validates :user_id, presence: true
  default_scope order: 'stacks.created_at DESC'

  def params_from_template
    j = JSON.parse(self.stack_template.body)
    j['Parameters'].each do |p| 
      param = self.stack_parameters.build()
      param.param_name = p[0]
      param.param_value = p[1]['Default']
    end
  end

  def resources_from_template
    j = JSON.parse(self.stack_template.body)
    j['Resources'].each {  |key, val|
      resource = self.stack_resources.build()
      resource.logical_id = key
      resource.typ = val['Type']
      resource.status = 'CREATE_IN_PROGRESS'
    }
  end

  def outputs_from_template
    j = JSON.parse(self.stack_template.body)
    j['Outputs'].each {  |key, val|
      output = self.stack_outputs.build()
      output.key = key
      output.value = val['Value']
      output.descr = val['Description']
    }
  end

  def launch
      parameters = {}
      self.stack_parameters.map{|p| parameters[p.param_name] = p.param_value}
      parameters['AWS::StackName'] = self.stack_name
      parameters['AWS::StackId'] = self.stack_id
      parameters['AWS::Region'] = 'us-east-1' #TODO handle this better
      templ = JSON.parse(self.stack_template.body)
      parser = StackMate::Stacker.new(self.stack_template.body, self.stack_name, parameters)
      pdef = process_definition(parser, templ)
      #logger.debug "pdef= #{pdef.inspect}"
      #logger.debug "parser.templ = #{parser.templ.inspect}"
      wfid = RUOTE.launch(pdef, parser.templ)
      logger.info  "Finished launch #{wfid}"
      update_attributes(:launched_at => Time.now, :ruote_wfid => wfid.to_s)
      wait_task = Thread.new(wfid, self.stack_name) { |wfid, stack_name|
          RUOTE.wait_for(wfid)
          errors = RUOTE.errors(wfid)
          logger.info "Stack completed execution"
          if errors.first
            logger.error { "engine error : #{RUOTE.errors(wfid).first.message}"} 
          else
            logger.info "Stack #{stack_name} completed execution"
          end
      }
      logger.info  "Finished launch #{wfid}"

  end

  def wait_condition (handle)
    j = JSON.parse(self.stack_template.body)
    #find the wait conditions that get unblocked by the supplied wait handle
    wait_conditions = j['Resources'].inject([]) {
        |result, (key, val)|  result << key if val['Type'] == 'AWS::CloudFormation::WaitCondition' && 
        val['Properties']['Handle']['Ref'] == handle;
        result
    }
    return if wait_conditions.empty? #TODO: throw exception?

    updated = 0
    wait_conditions.each { |w|
      resource = self.stack_resources.find_by_logical_id(w)
      condition = RUOTE.participant(w)
      if resource == nil or condition == nil
        logger.warn "Did not find wait handle #{handle} in db or workflow engine"
        break
      end
      #get the workitem by calling Ruote::StorageParticipant API
      wi = condition.by_participant(w)[0]
      if wi == nil
        logger.warn "Did not find work item for participant #{w}"
        break #TODO throw exception
      end
      #Tell the workflow to move forward
      condition.proceed(wi)
      #update the db
      resource.status = 'CREATE_COMPLETE'
      resource.save
      logger.info "Found wait handle #{handle} in db and workflow engine and unblocked wait condition #{w}"
      updated += 1
    }
    if updated == 0
      logger.warn "Did not find the handle #{handle} that can unblock any wait condition"
    end
  end


  private

    def create_stack_id
      self.stack_id = SecureRandom.urlsafe_base64
    end

    def process_definition (parser, templ)
        participants = parser.strongly_connected_components.flatten

        logger.info("Ordered list of participants: #{participants}")

        participants.each do |p|
            t = templ['Resources'][p]['Type']
            opts = {:stack_id => self.id, :participant => p, :typ => t, 
                :URL => ENV['CS_URL'], :APIKEY => self.user.api_key, :SECKEY => self.user.sec_key}
            RUOTE.register_participant p, Stacktician::Participants.class_for(t), opts
        end

        opts = {:stack_id => self.id}
        RUOTE.register_participant 'Output', Stacktician::Participants.class_for('Outputs'), opts
        #participants << 'Output'
        pdef = Ruote.define @stackname.to_s() do
            cursor :timeout => '300s', :on_error => 'rollback', :on_timeout => 'rollback' do
                participants.collect{ |name| __send__(name, :operation => :create) }
                __send__('Output')
            end
            define 'rollback', :timeout => '300s' do
                participants.reverse_each.collect {|name| __send__(name, :operation => :rollback) }
            end
        end

        pdef
    end
        
    end
