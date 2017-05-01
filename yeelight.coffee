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
      @propertyMappings = {
        power: "state"
        bright: "dimlevel"
        ct: "colorTemperature"
        rgb: "color"
        hue: "hue"
        sat: "saturation"
        color_mode: "colorMode"
        flowing: "flowing"
        delayoff: "delayoff"
        flow_params: "flowParams"
        music_on: "musicOn"
        name: "name"
      }
      @propertyValues = {}

      @initConnection()
      super()

    loadPropertyValues: () =>
      @sendRequest "get_prop", @propertyNames, (jsonData) =>
        for propertyName, index in @propertyNames
          propertyValue = jsonData.result[index]
          mappedPropertyName = @propertyMappings[propertyName]
          parsedPropertyValue = parseInt(propertyValue)
          if isNaN(parsedPropertyValue)
            if propertyValue is "on"
              parsedPropertyValue = true
            else if propertyValue is "off"
              parsedPropertyValue = false
            else
              parsedPropertyValue = propertyValue
          @propertyValues[mappedPropertyName] = parsedPropertyValue

        env.logger.debug("PropertyValues: #{JSON.stringify(@propertyValues, null, 2)}")

        if @propertyValues.state
          dimLevel = 0
        else
          dimLevel = @propertyValues.dimLevel
        env.logger.debug("Dim level: #{dimLevel}")
        @_setDimlevel dimLevel


    initConnection: () =>
      env.logger.debug("Connecting to #{@address} on port #{@port}")
      @connection = net.createConnection @port, @address, () =>
        env.logger.debug("Connected to #{@address} on port #{@port}")
        @loadPropertyValues()

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
            env.logger.error("Error while parsing json data '#{part}' for #{@address}: #{error}")
            continue

          @handleJsonResponse(jsonData)
                 
      @connection.on 'end', () =>
        env.logger.debug("Disconnected from #{@address}.")

      @connection.on 'error', () =>
        env.logger.debug("Error for connection to #{@address}.")

      @connection.on 'close', (had_error) =>
        retryInterval = 10000
        env.logger.debug("Socket close for #{@address}. Error: #{had_error}. Connect again in #{retryInterval} ms.")
        setTimeout(@initConnection, retryInterval)

      @connection.on 'timeout', () =>
        env.logger.debug("Timeout for #{@address}.")

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

      for key of params
        propertyValue = params[key]
        @propertyValues[key] = propertyValue
        propertyName = @propertyMappings[key]
        # Emit new value if present
        if propertyName? and propertyName not in ['state', dimlevel']
           env.logger.debug("Emit new value for #{propertyName}: #{propertyValue}.")
           @emit propertyName propertyValue

      if params.power?
        @_setState(params.power == "on")
      if params.bright?
        @_setDimlevel(params.bright)

    sendRequest: (method, params, responseHandler) =>
      if not @connection?
        env.logger.error("Socket not initialized for #{@address}.")
        return
      else if @connection.connecting
        env.logger.error("The socket for #{@address} is still connecting.")
        return
      else if @connection.destroyed
        env.logger.error("The socket for #{@address} is destroyed.")
        return

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
          

    attributes:
      dimlevel:
        description: "the current dim level"
        type: "number"
        unit: "%"
      state:
        description: "the current state of the switch"
        type: "boolean"
        labels: ['on', 'off']
      colorTemperature:
        description: "Color temperature. Range 1700 ~ 6500(k)"
        type: "number"
        unit: "K"
      color:
        description: "Color. Range 1 ~ 16777215"
        type: "number"
      hue:
        description: "Hue. Range 0 ~ 359"
        type: "number"
      saturation:
        description: "Saturation. Range 0 ~ 100"
        type: "number"
      colorMode:
        description: "1: rgb mode / 2: color temperature mode / 3: hsv mode"
        type: "number"
      flowing:
        description: "0: no flow is running / 1:color flow is running"
        type: "number"
      delayOff:
        description: "The remaining time of a sleep timer. Range 1 ~ 60 (minutes)"
        type: "number"
        unit: "m"
      flowParams:
        description: "Current flow parameters (only meaningful when 'flowing' is 1)"
        type: "string"
      musicOn:
        description: "1: Music mode is on / 0: Music mode is off"
        type: "number"
      name:
        description: "The name of the device set by 'set_name' command"
        type: "string"

    getColorTemperature: () => Promise.resolve(@propertyValues.colorTemperature)

    getColor: () => Promise.resolve(@propertyValues.color)

    getHue: () => Promise.resolve(@propertyValues.hue)

    getSaturation: () => Promise.resolve(@propertyValues.saturation)

    getColorMode: () => Promise.resolve(@propertyValues.colorMode)

    getFlowing: () => Promise.resolve(@propertyValues.flowing)

    getDelayOff: () => Promise.resolve(@propertyValues.delayOff)

    getFlowParams: () => Promise.resolve(@propertyValues.flowParams)

    getMusicOn: () => Promise.resolve(@propertyValues.musicOn)

    getName: () => Promise.resolve(@propertyValues.name)

  return new YeelightPlugin
