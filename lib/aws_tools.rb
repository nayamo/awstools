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
		def get_private_ip(instance_ids)
			instance_ids.collect do |instance_id|
				@aws_ec2.instances[instance_id].private_ip_address
			end
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
		def _subnet_to_availability_zone(subnet_id)
			subnet = @aws_ec2.subnets[subnet_id]
			subnet.availability_zone_name
		end
		#
		# Spot
		#
		class Spot < EC2
			#
			# hashの内容でスポットリクエストする
			#
			# @argument file (path)
			# @argument userdata_file (path)
			# @return spot_instance_request_ids[Array]
			#
			def instance_request(options={}, userdata_hash=nil)
				_instance_request(options, userdata_hash)
			end
			#
			# スポットリクエスト時に複数のインスタンスタイプ、価格を指定できる
			# price_historyの結果で指定した価格より高ければ次の候補に
			#
			# @return spot_instance_request_ids[Array]
			#
			def instance_request_with_candidates(options={}, userdata_hash=nil, candidates=[])
				if options['spot_price'] || options['launch_specification']['instance_type']
					raise 'options のインスタンスタイプ及びスポット価格に指定は必要ありません。' 
				end
				# スポット価格の履歴を取得
				res = get_price_history(
					:availability_zone=>_subnet_to_availability_zone( options['launch_specification']['subnet_id'] ),
					:start_time=>(Time.now.getutc-3600).iso8601,
					:end_time=>(Time.now.getutc).iso8601,
					:product_descriptions=>['Linux/UNIX (Amazon VPC)'],
					:instance_types=>candidates.collect {|elm| elm['instance_type'] }
				)
				elected_candidate = nil
				candidates.collect {|candidate|
					res.data[:spot_price_history_set].each {|spot_price_history|
						if spot_price_history[:instance_type] == candidate['instance_type']
							if candidate['spot_price'].to_f > spot_price_history[:spot_price].to_f
								elected_candidate = candidate
							end
							break
						end
						break if elected_candidate
					}
				}
				raise 'スポットインスタンスの価格が、指定したインスタンスタイプ全てで価格を上回っています。' if !elected_candidate
				options['spot_price'] =  elected_candidate['spot_price']
				options['launch_specification']['instance_type'] = elected_candidate['instance_type']
				# スポットリクエスト
				_instance_request(options, userdata_hash)
			end
			#
			# 指定したspot_request_idで起動したec2inctanceにtagをセットする
			#
			# @argument spot_instance_request_ids[Array]
			# @argument tags[Hash]
			#
			def set_spot_instance_tags(spot_request_ids, tags)
				_wait_ride_instance(spot_request_ids)
				instance_ids = _get_instance_ids(spot_request_ids)
				_set_instance_tags(instance_ids, tags)
			end

			def get_spot_instance_ids(spot_request_ids)
				_get_instance_ids(spot_request_ids)
			end

			def terminate_spot_instance(spot_request_ids)
				instance_ids = _get_instance_ids(spot_request_ids)
				_terminate_instance(instance_ids)
			end

			def get_price_history(options={})
				@aws_ec2.client.describe_spot_price_history(options)
			end

			private
			def _instance_request(options={}, userdata_hash=nil)
				if userdata_hash
					options['launch_specification'] = {} if !options['launch_specification']
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

