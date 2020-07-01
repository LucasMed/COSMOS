# encoding: ascii-8bit

# Copyright 2020 Ball Aerospace & Technologies Corp.
# All Rights Reserved.
#
# This program is free software; you can modify and/or redistribute it
# under the terms of the GNU General Public License
# as published by the Free Software Foundation; version 3 with
# attribution addendums as found in the LICENSE.txt

require 'spec_helper'
require 'cosmos'
require 'cosmos/tools/cmd_tlm_server/api'
require 'cosmos/microservices/interface_microservice'

module Cosmos
  describe Api do
    class ApiTest
      include Api
    end

    before(:each) do
      @redis = configure_store()

      # Create an Interface we can use in the InterfaceCmdHandlerThread
      # It has to have a valid list of target_names as that is what 'receive_commands'
      # in the Store uses to determine which topics to read
      interface = Interface.new
      interface.name = "INST_INT"
      interface.target_names = %w[INST]
      # Stub out write to make the InterfaceCmdHandlerThread happy
      allow(interface).to receive(:write) { |data| @interface_data = data }
      # Stub out as_json to make the call to Store.instance.set_interface happy
      allow(interface).to receive(:as_json).and_return({})
      @thread = InterfaceCmdHandlerThread.new(interface, nil)
      Store.instance.set_interface(interface, initialize: true)
      @process = true # Allow the command to be processed or not
      # Wrap xadd to allow us to process commands like the interface microservices
      # would in the real system.
      allow(@redis).to receive(:xadd).and_wrap_original do |m, *args|
        result = m.call(*args)
        # Run the InterfaceCmdHandlerThread to process the command
        # This will ack the command on the ACKCMDTARGET__<TGT> channel
        if @process && (args[0] =~ /^CMDTARGET/ || args[0] =~ /^CMDINTERFACE/)
          thread = Thread.new { @thread.run }
          thread.report_on_exception = false
          sleep 0.1 # Allow the thread to run
          thread.kill
          sleep 0.1 # Wait for the thread to be killed
        end
        result
      end
      # TODO: Initialize the offsets by reading once ... I don't think we should have to do this
      # topics = ["CMDINTERFACE__#{interface.name}"]
      # interface.target_names.each { |target_name| topics << "CMDTARGET__#{target_name}" }
      # Store.instance.read_topics(topics)

      @api = ApiTest.new
    end

    def test_cmd_unknown(method)
      expect { @api.send(method,"BLAH COLLECT with TYPE NORMAL") }.to raise_error(/does not exist/)
      expect { @api.send(method,"INST UNKNOWN with TYPE NORMAL") }.to raise_error(/does not exist/)
      expect { @api.send(method,"INST COLLECT with BLAH NORMAL") }.to raise_error(/does not exist/)
      expect { @api.send(method,"BLAH","COLLECT","TYPE"=>"NORMAL") }.to raise_error(/does not exist/)
      expect { @api.send(method,"INST","UNKNOWN","TYPE"=>"NORMAL") }.to raise_error(/does not exist/)
      expect { @api.send(method,"INST","COLLECT","BLAH"=>"NORMAL") }.to raise_error(/does not exist/)
    end

    describe "cmd" do
      it "complains about unknown targets, commands, and parameters" do
        test_cmd_unknown(:cmd)
        sleep(0.5)
      end

      it "processes a string" do
        target_name, cmd_name, params = @api.cmd("INST COLLECT with TYPE NORMAL, DURATION 5")
        expect(target_name).to eql 'INST'
        expect(cmd_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>'NORMAL', 'DURATION'=>5)
      end

      it "complains if parameters are not separated by commas" do
        expect { @api.cmd("INST COLLECT with TYPE NORMAL DURATION 5") }.to raise_error(/Missing comma/)
      end

      it "complains if parameters don't have values" do
        expect { @api.cmd("INST COLLECT with TYPE") }.to raise_error(/Missing value/)
      end

      it "processes parameters" do
        target_name, cmd_name, params = @api.cmd("INST","COLLECT","TYPE"=>"NORMAL","DURATION"=>5)
        expect(target_name).to eql 'INST'
        expect(cmd_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>'NORMAL', 'DURATION'=>5)
      end

      it "processes commands without parameters" do
        target_name, cmd_name, params = @api.cmd("INST","ABORT")
        expect(target_name).to eql 'INST'
        expect(cmd_name).to eql 'ABORT'
        expect(params).to be {}
      end

      it "complains about too many parameters" do
        expect { @api.cmd("INST","COLLECT","TYPE","DURATION") }.to raise_error(/Invalid number of arguments/)
      end

      it "warns about required parameters" do
        expect { @api.cmd("INST COLLECT with DURATION 5") }.to raise_error(/Required/)
      end

      it "warns about out of range parameters" do
        expect { @api.cmd("INST COLLECT with TYPE NORMAL, DURATION 1000") }.to raise_error(/not in valid range/)
      end

      it "warns about hazardous parameters" do
        expect { @api.cmd("INST COLLECT with TYPE SPECIAL") }.to raise_error(/Hazardous/)
      end

      it "warns about hazardous commands" do
        expect { @api.cmd("INST CLEAR") }.to raise_error(/Hazardous/)
      end

      it "times out if the interface does not process the command" do
        @process = false
        expect { @api.cmd("INST","ABORT") }.to raise_error("Timeout waiting for cmd ack")
      end
    end

    describe "cmd_no_range_check" do
      it "complains about unknown targets, commands, and parameters" do
        test_cmd_unknown(:cmd_no_range_check)
      end

      it "processes a string" do
        target_name, cmd_no_range_check_name, params = @api.cmd_no_range_check("INST COLLECT with TYPE NORMAL, DURATION 5")
        expect(target_name).to eql 'INST'
        expect(cmd_no_range_check_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>'NORMAL', 'DURATION'=>5)
      end

      it "processes parameters" do
        target_name, cmd_no_range_check_name, params = @api.cmd_no_range_check("INST","COLLECT","TYPE"=>"NORMAL","DURATION"=>5)
        expect(target_name).to eql 'INST'
        expect(cmd_no_range_check_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>'NORMAL', 'DURATION'=>5)
      end

      it "warns about required parameters" do
        expect { @api.cmd_no_range_check("INST COLLECT with DURATION 5") }.to raise_error(/Required/)
      end

      it "does not warn about out of range parameters" do
        expect { @api.cmd_no_range_check("INST COLLECT with TYPE NORMAL, DURATION 1000") }.to_not raise_error
      end

      it "warns about hazardous parameters" do
        expect { @api.cmd_no_range_check("INST COLLECT with TYPE SPECIAL") }.to raise_error(/Hazardous/)
      end

      it "warns about hazardous commands" do
        expect { @api.cmd_no_range_check("INST CLEAR") }.to raise_error(/Hazardous/)
      end
    end

    describe "cmd_no_hazardous_check" do
      it "complains about unknown targets, commands, and parameters" do
        test_cmd_unknown(:cmd_no_hazardous_check)
      end

      it "processes a string" do
        target_name, cmd_no_hazardous_check_name, params = @api.cmd_no_hazardous_check("INST COLLECT with TYPE NORMAL, DURATION 5")
        expect(target_name).to eql 'INST'
        expect(cmd_no_hazardous_check_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>'NORMAL', 'DURATION'=>5)
      end

      it "processes parameters" do
        target_name, cmd_no_hazardous_check_name, params = @api.cmd_no_hazardous_check("INST","COLLECT","TYPE"=>"NORMAL","DURATION"=>5)
        expect(target_name).to eql 'INST'
        expect(cmd_no_hazardous_check_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>'NORMAL', 'DURATION'=>5)
      end

      it "processes parameters that are strings" do
        target_name, cmd_name, params = @api.cmd_no_hazardous_check("INST ASCIICMD with STRING 'ARM LASER'")
        expect(target_name).to eql 'INST'
        expect(cmd_name).to eql 'ASCIICMD'
        expect(params).to include('STRING'=>'ARM LASER')
      end

      it "warns about required parameters" do
        expect { @api.cmd_no_hazardous_check("INST COLLECT with DURATION 5") }.to raise_error(/Required/)
      end

      it "warns about out of range parameters" do
        expect { @api.cmd_no_hazardous_check("INST COLLECT with TYPE NORMAL, DURATION 1000") }.to raise_error(/not in valid range/)
      end

      it "does not warn about hazardous parameters" do
        expect { @api.cmd_no_hazardous_check("INST COLLECT with TYPE SPECIAL") }.to_not raise_error
      end

      it "does not warn about hazardous commands" do
        expect { @api.cmd_no_hazardous_check("INST CLEAR") }.to_not raise_error
      end
    end

    describe "cmd_no_checks" do
      it "complains about unknown targets, commands, and parameters" do
        test_cmd_unknown(:cmd_no_checks)
      end

      it "processes a string" do
        target_name, cmd_no_checks_name, params = @api.cmd_no_checks("INST COLLECT with TYPE NORMAL, DURATION 5")
        expect(target_name).to eql 'INST'
        expect(cmd_no_checks_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>'NORMAL', 'DURATION'=>5)
      end

      it "processes parameters" do
        target_name, cmd_no_checks_name, params = @api.cmd_no_checks("INST","COLLECT","TYPE"=>"NORMAL","DURATION"=>5)
        expect(target_name).to eql 'INST'
        expect(cmd_no_checks_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>'NORMAL', 'DURATION'=>5)
      end

      it "warns about required parameters" do
        expect { @api.cmd_no_checks("INST COLLECT with DURATION 5") }.to raise_error(/Required/)
      end

      it "does not warn about out of range parameters" do
        expect { @api.cmd_no_checks("INST COLLECT with TYPE NORMAL, DURATION 1000") }.to_not raise_error
      end

      it "does not warn about hazardous parameters" do
        expect { @api.cmd_no_checks("INST COLLECT with TYPE SPECIAL") }.to_not raise_error
      end

      it "does not warn about hazardous commands" do
        expect { @api.cmd_no_checks("INST CLEAR") }.to_not raise_error
      end
    end

    describe "cmd_raw" do
      it "complains about unknown targets, commands, and parameters" do
        test_cmd_unknown(:cmd_raw)
      end

      it "processes a string" do
        target_name, cmd_name, params = @api.cmd_raw("INST COLLECT with TYPE 0, DURATION 5")
        expect(target_name).to eql 'INST'
        expect(cmd_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>0, 'DURATION'=>5)
      end

      it "complains if parameters are not separated by commas" do
        expect { @api.cmd_raw("INST COLLECT with TYPE 0 DURATION 5") }.to raise_error(/Missing comma/)
      end

      it "complains if parameters don't have values" do
        expect { @api.cmd_raw("INST COLLECT with TYPE") }.to raise_error(/Missing value/)
      end

      it "processes parameters" do
        target_name, cmd_name, params = @api.cmd_raw("INST","COLLECT","TYPE"=>0,"DURATION"=>5)
        expect(target_name).to eql 'INST'
        expect(cmd_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>0, 'DURATION'=>5)
      end

      it "processes commands without parameters" do
        target_name, cmd_name, params = @api.cmd_raw("INST","ABORT")
        expect(target_name).to eql 'INST'
        expect(cmd_name).to eql 'ABORT'
        expect(params).to be {}
      end

      it "complains about too many parameters" do
        expect { @api.cmd_raw("INST","COLLECT","TYPE","DURATION") }.to raise_error(/Invalid number of arguments/)
      end

      it "warns about required parameters" do
        expect { @api.cmd_raw("INST COLLECT with DURATION 5") }.to raise_error(/Required/)
      end

      it "warns about out of range parameters" do
        expect { @api.cmd_raw("INST COLLECT with TYPE 0, DURATION 1000") }.to raise_error(/not in valid range/)
      end

      it "warns about hazardous parameters" do
        expect { @api.cmd_raw("INST COLLECT with TYPE 1") }.to raise_error(/Hazardous/)
      end

      it "warns about hazardous commands" do
        expect { @api.cmd_raw("INST CLEAR") }.to raise_error(/Hazardous/)
      end
    end

    describe "cmd_no_range_check" do
      it "complains about unknown targets, commands, and parameters" do
        test_cmd_unknown(:cmd_raw_no_range_check)
      end

      it "processes a string" do
        target_name, cmd_no_range_check_name, params = @api.cmd_raw_no_range_check("INST COLLECT with TYPE 0, DURATION 5")
        expect(target_name).to eql 'INST'
        expect(cmd_no_range_check_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>0, 'DURATION'=>5)
      end

      it "processes parameters" do
        target_name, cmd_no_range_check_name, params = @api.cmd_raw_no_range_check("INST","COLLECT","TYPE"=>0,"DURATION"=>5)
        expect(target_name).to eql 'INST'
        expect(cmd_no_range_check_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>0, 'DURATION'=>5)
      end

      it "warns about required parameters" do
        expect { @api.cmd_raw_no_range_check("INST COLLECT with DURATION 5") }.to raise_error(/Required/)
      end

      it "does not warn about out of range parameters" do
        expect { @api.cmd_raw_no_range_check("INST COLLECT with TYPE 0, DURATION 1000") }.to_not raise_error
      end

      it "warns about hazardous parameters" do
        expect { @api.cmd_raw_no_range_check("INST COLLECT with TYPE 1") }.to raise_error(/Hazardous/)
      end

      it "warns about hazardous commands" do
        expect { @api.cmd_raw_no_range_check("INST CLEAR") }.to raise_error(/Hazardous/)
      end
    end

    describe "cmd_raw_no_hazardous_check" do
      it "complains about unknown targets, commands, and parameters" do
        test_cmd_unknown(:cmd_raw_no_hazardous_check)
      end

      it "processes a string" do
        target_name, cmd_no_hazardous_check_name, params = @api.cmd_raw_no_hazardous_check("INST COLLECT with TYPE 0, DURATION 5")
        expect(target_name).to eql 'INST'
        expect(cmd_no_hazardous_check_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>0, 'DURATION'=>5)
      end

      it "processes parameters" do
        target_name, cmd_no_hazardous_check_name, params = @api.cmd_raw_no_hazardous_check("INST","COLLECT","TYPE"=>0,"DURATION"=>5)
        expect(target_name).to eql 'INST'
        expect(cmd_no_hazardous_check_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>0, 'DURATION'=>5)
      end

      it "processes parameters that are strings" do
        target_name, cmd_name, params = @api.cmd_raw_no_hazardous_check("INST ASCIICMD with STRING 'ARM LASER'")
        expect(target_name).to eql 'INST'
        expect(cmd_name).to eql 'ASCIICMD'
        expect(params).to include('STRING'=>'ARM LASER')
      end

      it "warns about required parameters" do
        expect { @api.cmd_raw_no_hazardous_check("INST COLLECT with DURATION 5") }.to raise_error(/Required/)
      end

      it "warns about out of range parameters" do
        expect { @api.cmd_raw_no_hazardous_check("INST COLLECT with TYPE 0, DURATION 1000") }.to raise_error(/not in valid range/)
      end

      it "does not warn about hazardous parameters" do
        expect { @api.cmd_raw_no_hazardous_check("INST COLLECT with TYPE 1") }.to_not raise_error
      end

      it "does not warn about hazardous commands" do
        expect { @api.cmd_raw_no_hazardous_check("INST CLEAR") }.to_not raise_error
      end
    end

    describe "cmd_raw_no_checks" do
      it "complains about unknown targets, commands, and parameters" do
        test_cmd_unknown(:cmd_raw_no_checks)
      end

      it "processes a string" do
        target_name, cmd_no_checks_name, params = @api.cmd_raw_no_checks("INST COLLECT with TYPE 0, DURATION 5")
        expect(target_name).to eql 'INST'
        expect(cmd_no_checks_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>0, 'DURATION'=>5)
      end

      it "processes parameters" do
        target_name, cmd_no_checks_name, params = @api.cmd_raw_no_checks("INST","COLLECT","TYPE"=>0,"DURATION"=>5)
        expect(target_name).to eql 'INST'
        expect(cmd_no_checks_name).to eql 'COLLECT'
        expect(params).to include('TYPE'=>0, 'DURATION'=>5)
      end

      it "warns about required parameters" do
        expect { @api.cmd_raw_no_checks("INST COLLECT with DURATION 5") }.to raise_error(/Required/)
      end

      it "does not warn about out of range parameters" do
        expect { @api.cmd_raw_no_checks("INST COLLECT with TYPE 0, DURATION 1000") }.to_not raise_error
      end

      it "does not warn about hazardous parameters" do
        expect { @api.cmd_raw_no_checks("INST COLLECT with TYPE 1") }.to_not raise_error
      end

      it "does not warn about hazardous commands" do
        expect { @api.cmd_raw_no_checks("INST CLEAR") }.to_not raise_error
      end
    end

    describe "get_cmd_buffer" do
      it "complains about unknown commands" do
        expect { @api.get_cmd_buffer("INST", "BLAH") }.to raise_error(/does not exist/)
      end

      it "returns nil if the command has not yet been sent" do
        expect(@api.get_cmd_buffer("INST", "ABORT")).to be_nil
      end

      it "returns a command packet buffer" do
        @api.cmd("INST ABORT")
        expect(@api.get_cmd_buffer("INST", "ABORT")[6..7].unpack("n")[0]).to eq 2
        @api.cmd("INST COLLECT with TYPE NORMAL, DURATION 5")
        expect(@api.get_cmd_buffer("INST", "COLLECT")[6..7].unpack("n")[0]).to eq 1
      end
    end

    describe "send_raw" do
      it "sends raw data to an interface" do
        @api.send_raw("INST_INT", "\x00\x01\x02\x03")
        expect(@interface_data).to eql "\x00\x01\x02\x03"
      end
    end

    # DEPRECATED: use get_all_commands
    describe "get_cmd_list" do
      it "returns command names sorted" do
        result = @api.get_cmd_list("INST")
        expect(result.sort).to eql result
      end

      it "complains with a unknown target" do
        expect { @api.get_cmd_list("BLAH") }.to raise_error(/does not exist/)
      end

      it "returns command names and descriptions for a given target" do
        result = @api.get_cmd_list("INST")
        expect(result[0][0]).to eql "ABORT"
        # The second parameter is the description ... only test one
        expect(result[0][1]).to eql "Aborts a collect on the instrument"
        expect(result[1][0]).to eql "ARYCMD"
        expect(result[2][0]).to eql "ASCIICMD"
        expect(result[3][0]).to eql "CLEAR"
        expect(result[4][0]).to eql "COLLECT"
        expect(result[5][0]).to eql "COSMOS_ERROR_HANDLE"
        expect(result[6][0]).to eql "COSMOS_ERROR_IGNORE"
        expect(result[7][0]).to eql "COSMOS_HANDSHAKE_DS"
        expect(result[8][0]).to eql "COSMOS_HANDSHAKE_EN"
        expect(result[9][0]).to eql "FLTCMD"
        expect(result[10][0]).to eql "LINC_COMMAND"
        expect(result[11][0]).to eql "SETPARAMS"
        expect(result[12][0]).to eql "SLRPNLDEPLOY"
        expect(result[13][0]).to eql "SLRPNLRESET"
      end
    end

    describe 'get_all_commands' do
      it "complains with a unknown target" do
        expect { @api.get_all_commands("BLAH") }.to raise_error(/does not exist/)
      end

      it "returns an array of commands as hashes" do
        result = @api.get_all_commands("INST")
        expect(result).to be_a Array
        result.each do |command|
          expect(command).to be_a Hash
          expect(command['target_name']).to eql("INST")
          expect(command.keys).to include(*%w(target_name packet_name description endianness items))
        end
      end
    end

    # DEPRECATED: use get_command_parameters
    describe "get_cmd_param_list" do
      it "returns parameters for the command" do
        result = @api.get_cmd_param_list("INST","COLLECT")
        # Each element in the results array contains:
        #   name, default, states, description, full units, units, required
        expect(result).to include ['TYPE',0,{"NORMAL"=>0,"SPECIAL"=>1},'Collect type',nil,nil,true,"UINT"]
        expect(result).to include ['TEMP',0.0,nil,'Collect temperature','Celsius','C',false,"FLOAT"]
      end

      it "returns array parameters for the command" do
        result = @api.get_cmd_param_list("INST","ARYCMD")
        # Each element in the results array contains:
        #   name, default, states, description, full units, units, required
        expect(result).to include ['ARRAY',[],nil,'Array parameter',nil,nil,false,"FLOAT"]
        # Since ARRAY2 has a format string the default is in quotes
        expect(result).to include ['ARRAY2',"[]",nil,'Array parameter',nil,nil,false,"UINT"]
      end
    end

    describe "get_parameter" do
      it "returns parameter hash for state parameter" do
        result = @api.get_parameter("INST","COLLECT","TYPE")
        expect(result['name']).to eql "TYPE"
        expect(result['states'].keys.sort).to eql %w[NORMAL SPECIAL]
        expect(result['states']['NORMAL']).to include("value" => 0)
        expect(result['states']['SPECIAL']).to include("value" => 1, "hazardous" => "")
      end

      it "returns parameter hash for array parameter" do
        result = @api.get_parameter("INST","ARYCMD","ARRAY")
        expect(result['name']).to eql "ARRAY"
        expect(result['bit_size']).to eql 64
        expect(result['array_size']).to eql 640
        expect(result['data_type']).to eql "FLOAT"
      end
    end

    describe 'get_command' do
      it "returns hash for the command" do
        result = @api.get_command("INST","COLLECT")
        expect(result).to be_a Hash
        expect(result['target_name']).to eql "INST"
        expect(result['packet_name']).to eql "COLLECT"
        result['items'].each do |parameter|
          expect(parameter).to be_a Hash
          expect(parameter.keys).to include(*%w(name bit_offset bit_size data_type description default minimum maximum endianness overflow))
        end
      end
    end

    describe "get_cmd_hazardous" do
      it "returns whether the command with parameters is hazardous" do
        expect(@api.get_cmd_hazardous("INST","COLLECT",{"TYPE"=>"NORMAL"})).to be false
        expect(@api.get_cmd_hazardous("INST","COLLECT",{"TYPE"=>"SPECIAL"})).to be true
      end

      it "returns whether the command is hazardous" do
        expect(@api.get_cmd_hazardous("INST","CLEAR")).to be true
      end
    end

    describe "get_cmd_value" do
      it "returns command values" do
        time = Time.now
        packet = System.commands.packet("INST", "COLLECT")
        packet.received_time = time
        packet.restore_defaults
        packet.received_count = 5
        expect(@api.get_cmd_value("INST", "COLLECT", "TYPE")).to eql 'NORMAL'
        expect(@api.get_cmd_value("INST", "COLLECT", "RECEIVED_TIMEFORMATTED")).to eql time.formatted
        expect(@api.get_cmd_value("INST", "COLLECT", "RECEIVED_TIMESECONDS")).to eql time.to_f
        expect(@api.get_cmd_value("INST", "COLLECT", "PACKET_TIMEFORMATTED")).to eql time.formatted
        expect(@api.get_cmd_value("INST", "COLLECT", "PACKET_TIMESECONDS")).to eql time.to_f
        expect(@api.get_cmd_value("INST", "COLLECT", "RECEIVED_COUNT")).to eql 5
      end

      it "returns special values for time if time isn't set" do
        packet = System.commands.packet("INST", "COLLECT")
        packet.received_time = nil
        packet.restore_defaults
        packet.received_count = 5
        expect(@api.get_cmd_value("INST", "COLLECT", "TYPE")).to eql 'NORMAL'
        expect(@api.get_cmd_value("INST", "COLLECT", "RECEIVED_TIMEFORMATTED")).to eql "No Packet Received Time"
        expect(@api.get_cmd_value("INST", "COLLECT", "RECEIVED_TIMESECONDS")).to eql 0.0
        expect(@api.get_cmd_value("INST", "COLLECT", "PACKET_TIMEFORMATTED")).to eql "No Packet Time"
        expect(@api.get_cmd_value("INST", "COLLECT", "PACKET_TIMESECONDS")).to eql 0.0
        expect(@api.get_cmd_value("INST", "COLLECT", "RECEIVED_COUNT")).to eql 5
      end
    end

    describe "get_cmd_time" do
      it "returns command times" do
        time = Time.now
        time2 = Time.now + 2
        collect_cmd = System.commands.packet("INST", "COLLECT")
        collect_cmd.received_time = time
        abort_cmd = System.commands.packet("INST", "ABORT")
        abort_cmd.received_time = time + 1
        packet2 = System.commands.packet("SYSTEM", "STARTLOGGING")
        packet2.received_time = time2
        expect(@api.get_cmd_time()).to eql ['SYSTEM', 'STARTLOGGING', time2.tv_sec, time2.tv_usec]
        expect(@api.get_cmd_time('INST')).to eql ['INST', 'ABORT', time.tv_sec + 1, time.tv_usec]
        expect(@api.get_cmd_time('SYSTEM')).to eql ['SYSTEM', 'STARTLOGGING', time2.tv_sec, time2.tv_usec]
        expect(@api.get_cmd_time('INST', 'COLLECT')).to eql ['INST', 'COLLECT', time.tv_sec, time.tv_usec]
        expect(@api.get_cmd_time('SYSTEM', 'STARTLOGGING')).to eql ['SYSTEM', 'STARTLOGGING', time2.tv_sec, time2.tv_usec]
      end

      it "returns nil if no times are set" do
        System.commands.packets("INST").each { |name, pkt| pkt.received_time = nil }
        expect(@api.get_cmd_time("INST")).to eql [nil, nil, nil, nil]
        expect(@api.get_cmd_time("INST", "ABORT")).to eql ["INST", "ABORT", nil, nil]
      end
    end
  end
end
