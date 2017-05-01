module.exports = (env) ->
  # Require the  bluebird promise library
  Promise = env.require 'bluebird'

  # Require the [cassert library](https://github.com/rhoot/cassert).
  assert = env.require 'cassert'

  net = env.require 'net'

  class YeelightPlugin extends env.plugins.Plugin

    init: (app, @framework, @config) =>
      deviceConfigDef = require("./device-config-schema")

      @framework.deviceManager.registerDeviceClass("YeelightBulb", {
        configDef: deviceConfigDef.YeelightBulb,
        createCallback: (config, lastState) => new YeelightBulb(config, lastState)
      })

  class YeelightBulb extends env.devices.DimmerActuator

    constructor: (@config, lastState) ->
      #env.logger.debug("Config: #{JSON.stringify(@config, null, 2)}")
      @name = @config.name
      @id = @config.id
      @address = @config.address
      @port = @config.port
      @smoothDuration = @config.smoothDuration

      @requestCounter = 0
      @requests = {}
      @propertyNames = ["power", "bright", "ct", "rgb", "hue", "sat", "color_mode", "flowing", "delayoff", "flow_params", "music_on", "name"]

      @initConnection()
      super()

    initConnection: () ->
      env.logger.debug("Connecting to #{@address} on port #{@port}")
      @connection = net.createConnection @port, @address, () =>
        env.logger.debug("Connected to #{@address} on port #{@port}")

        @sendRequest "get_prop", ["power", "bright"], (jsonData) =>
          if jsonData.result[0] is "off"
            initialDimLevel = 0
          else
            initialDimLevel = jsonData.result[1] 
          env.logger.debug("Initial dim level: #{initialDimLevel}")
          @_setDimlevel initialDimLevel

          

      @connection.on 'data', (data) =>
        parts = data.toString().split("\n")
        for part in parts
          partTrimmed = part.trim()
          if not partTrimmed
            continue
          jsonData = null
          try
            jsonData = JSON.parse(part)
          catch error
            env.logger.error("Error while parsing json data '#{data}' for #{@address}: #{error}")
            continue

          @handleJsonResponse(jsonData)
                 
      @connection.on 'end', () =>
        env.logger.debug("Disconnected from #{@address}")
        @initConnection()

    handleJsonResponse: (jsonData) =>
      env.logger.debug("Received data: #{JSON.stringify(jsonData, null, 2)}")

      if jsonData.id?
        handler = @requests[jsonData.id]

        if not handler?
          #env.logger.debug("No handler found for id: #{jsonData.id}")
        else
          handler jsonData
          # Delete handler
          delete @requests[jsonData.id]
      else
        # handle message with no id
        if jsonData.method == "props" && jsonData.params?
           @handlePropsParams(jsonData.params)
        else
           env.logger.warn("Method is '#{jsonData.method}'. Ignore message.")

    handlePropsParams: (params) =>
      env.logger.debug("Handle props params: #{JSON.stringify(params, null, 2)}")
      if params.power?
        @_setState(params.power == "on")
      else if params.bright?
        @_setDimlevel(params.bright)
      else
        env.logger.warn("Unknown params: #{JSON.stringify(params, null, 2)}")

    sendRequest: (method, params, responseHandler) ->
      id = @requestCounter++

      if responseHandler?
        @requests[id] = responseHandler
      request = {
        id: id
        method: method
        params: params
      }
      jsonString = JSON.stringify(request)
      env.logger.debug("Sending request: #{jsonString}")
      @connection.write(jsonString + "\r\n")

    changeDimlevelTo: (state) =>
      env.logger.debug("Current state: #{@_state}")
      # check the current state of the lightbulb
      if not @_state
        if state > 0
          # Turn on sudden and then set dimmer level accordingly
          @sendRequest "set_power", ["on", "sudden", 1], (jsonData) =>
            env.logger.debug("set_power on, response: #{JSON.stringify(jsonData, null, 2)}")
            @sendRequest "set_bright", @getValueArray(state)
        else
          # Do nothing
      else if state == 0
         # Turn off
         @sendRequest "set_power", @getValueArray("off")
      else
         #set State
         @sendRequest "set_bright", @getValueArray(state)
            
    getValueArray: (value) =>
      if @smoothDuration < 30
        return [value, "sudden", 1]
      else
         return [value, "smooth", @smoothDuration] 
          

  return new YeelightPlugin
