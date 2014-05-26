#!/bin/env ruby
# -*- coding: utf-8 -*-

require "aws-sdk"
require "yaml"
require "json"
require 'base64'
require "pp"


AWS.config(YAML.load_file(File.dirname(__FILE__)+'/../config/awsconf.yml'))


#
# AWSTools
#
class AWSTools
	#
	# EC2
	#
	class EC2
		def initialize
			@aws_ec2 = AWS::EC2.new
		end

		private
		def _set_instance_tags(instance_ids, tags)
			instance_ids.each do |instance_id|
				@aws_ec2.instances[instance_id].tags.set(tags)
			end
		end
		def _terminate_instance(instance_ids)
			instance_ids.each do |instance_id|
				@aws_ec2.instances[instance_id].terminate
			end
		end
		#
		# Spot
		#
		class Spot < EC2
			# jsonファイルの内容でスポットリクエストする
			#
			# @argument file (path)
			# @argument userdata_file (path)
			# @return spot_instance_request_ids[Array]
			def instance_request(options={}, userdata_hash=nil)
				# options = JSON.parse(File.read(file))
				if userdata_hash
					options['launch_specification'] = {} if !options['launch_specification']
					# options['launch_specification']['user_data'] = Base64.encode64(File.read(userdata_file))
					options['launch_specification']['user_data'] = Base64.encode64( JSON.dump(userdata_hash) )
				end
				spot_response = @aws_ec2.client.request_spot_instances(options)
				spot_instance_request_ids = spot_response[:spot_instance_request_set].collect{|elm| elm[:spot_instance_request_id] }
				# AWS上で スポットリクエストのハンドラ？ が立ち上がるまで待機(稀にすぐに立ち上がらない事があるから)
				safety_counter = 0
				begin
					@aws_ec2.client.describe_spot_instance_requests(:spot_instance_request_ids=>spot_instance_request_ids)
				rescue =>e
					sleep 1
					safety_counter += 1
					raise e if safety_counter > 60
				end
				return spot_instance_request_ids
			end 
			# 指定したspot_request_idで起動したec2inctanceにtagをセットする
			#
			# @argument spot_instance_request_ids[Array]
			# @argument tags[Hash]
			def set_spot_instance_tags(spot_request_ids, tags)
				_wait_ride_instance(spot_request_ids)
				instance_ids = _get_instance_ids(spot_request_ids)
				_set_instance_tags(instance_ids, tags)
			end

			def terminate_spot_instance(spot_request_ids)
				instance_ids = _get_instance_ids(spot_request_ids)
				_terminate_instance(instance_ids)
			end

			private
			# インスタンスが立ち上がるまで待機
			def _wait_ride_instance(spot_request_ids=[], wait_sec=600)
				interval = 10
				describe_spot_response = @aws_ec2.client.describe_spot_instance_requests(:spot_instance_request_ids=>spot_request_ids)
				state_open_count = describe_spot_response[:spot_instance_request_set].select{|elm| elm[:state] == 'open' }.length
				wait_sum = 0
				while state_open_count > 0
					sleep interval
					wait_sum += interval
					raise RideInstanceWaitSecOver if wait_sum >= wait_sec
					describe_spot_response = @aws_ec2.client.describe_spot_instance_requests(:spot_instance_request_ids=>spot_request_ids)
					state_open_count = describe_spot_response[:spot_instance_request_set].select{|elm| elm[:state] == 'open' }.length
				end
			end

			def _get_instance_ids(spot_request_ids=[])
				describe_spot_response = @aws_ec2.client.describe_spot_instance_requests(:spot_instance_request_ids=>spot_request_ids)
				describe_spot_response[:spot_instance_request_set].select{|elm| elm[:state] == 'active'}.collect{|elm| elm[:instance_id] }
			end

			# 例外クラス
			class RideInstanceWaitSecOver < StandardError; end
		end
	end
	#
	# CloudWatch
	#
	class CloudWatch
		def initialize
			@aws_cw = AWS::CloudWatch.new
		end

		def create_alarm(alarm_name, options={})
			@aws_cw.alarms.create( alarm_name, options)
		end

		# テスト用
		def get_alarm_dimensions(alarm_name)
			@aws_cw.alarms[alarm_name].dimensions
		end
		def get_alarm_actions(alarm_name)
			@aws_cw.alarms[alarm_name].alarm_actions
		end
	end
	#
	# AutoScaling
	#
	class AutoScaling
		def initialize
			@aws_auto_scaling = AWS::AutoScaling.new
		end

		def execute_policy(options={})
			@aws_auto_scaling.client.execute_policy(options)
		end

		def get_instance_ids(group_name)
			group = @aws_auto_scaling.groups[group_name]
			group.auto_scaling_instances.to_ary
		end
	end
end

