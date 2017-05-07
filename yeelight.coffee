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
      @propertyNames = ["power", "bright", "ct", "rgb", "hue", "sat", "color_mode"]#, "flowing", "delayoff", "flow_params", "music_on", "name"]
      @booleanPropertyNames = ["power"]#, "flowing", "music_on"]
      @propertyValues = {}

      @initConnection()
      super()

    loadPropertyValues: () =>
      @sendRequest "get_prop", @propertyNames
      .then (jsonData) =>
        for propertyName, index in @propertyNames
          propertyValue = jsonData.result[index]
          @setPropertyValue propertyName, propertyValue

        env.logger.debug("PropertyValues: #{JSON.stringify(@propertyValues, null, 2)}")

        if not @propertyValues.power
          dimlevel = 0
        else
          dimlevel = @propertyValues.bright
        env.logger.debug("Dim level: #{dimlevel}")
        @_setDimlevel dimlevel
        @updateRGBValues()


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
        if jsonData.method == "props" and jsonData.params?
           @handlePropsParams(jsonData.params)
        else
           env.logger.warn("Method is '#{jsonData.method}'. Ignore message.")

    setPropertyValue: (propertyName, propertyValue) =>
       if propertyName in @booleanPropertyNames
         if propertyValue in ["on", "true"] or propertyValue == 1
           parsedPropertyValue = true
         else
           parsedPropertyValue = false
       else
         parsedPropertyValue = parseInt(propertyValue)

       if isNaN(parsedPropertyValue)
         parsedPropertyValue = propertyValue

       @propertyValues[propertyName] = parsedPropertyValue

    handlePropsParams: (params) =>
      env.logger.debug("Handle props params: #{JSON.stringify(params, null, 2)}")

      updateRGBValues = false

      for propertyName of params
        if propertyName in ['ct', 'rgb', 'hue', 'sat', 'color_mode']
          updateRGBValues = true

        propertyValue = params[propertyName]
        @setPropertyValue propertyName, propertyValue

      if params.power is "off"
        env.logger.debug("@_setDimlevel -> 0")
        @_setDimlevel 0
      else if params.power? or params.bright?
        env.logger.debug("@_setDimlevel -> #{@propertyValues.bright}")
        @_setDimlevel @propertyValues.bright

      env.logger.debug("PropertyValues: #{JSON.stringify(@propertyValues, null, 2)}")
      if updateRGBValues
        @updateRGBValues()

    updateRGBValues: () =>
      colorMode = @propertyValues.color_mode
      if colorMode == 1
        # rgb mode
        colorValue = @propertyValues.rgb
        env.logger.debug("Update from rgb value: #{colorValue}")
        @blue = colorValue % 255
        colorValue = Math.floor(colorValue / 255)
        @green = colorValue % 255
        @red = Math.floor(colorValue / 255)
      else if colorMode == 2
        # color temperature mode
        rgbValues = @colorTemperatureToRGB @propertyValues.ct
        env.logger.debug("Update from color temperature: #{@propertyValues.ct} -> #{JSON.stringify(rgbValues, null, 2)}")
        @red = Math.round(rgbValues.r)
        @green = Math.round(rgbValues.g)
        @blue = Math.round(rgbValues.b)
      else if colorMode == 3
        # hsv mode
        rgbValues = @hslToRgb @propertyValues.hue / 360.0, @propertyValues.sat / 100.0, @propertyValues.bright / 100.0
        env.logger.debug("Update from hsv mode: #{@propertyValues.hue}, #{@propertyValues.sat} -> #{JSON.stringify(rgbValues, null, 2)}")
        @red = Math.round(rgbValues.r)
        @green = Math.round(rgbValues.g)
        @blue = Math.round(rgbValues.b)
      else
        env.logger.error("Unknown color mode: #{colorMode}")
        return

      @emit "red", @red
      @emit "green", @green
      @emit "blue", @blue

    # From http://www.tannerhelland.com/4435/convert-temperature-rgb-algorithm-code/
    colorTemperatureToRGB: (kelvin) =>
      temp = kelvin / 100
      if temp <= 66
        red = 255
        green = temp
        green = 99.4708025861 * Math.log(green) - 161.1195681661

        if temp <= 19
          blue = 0
        else
          blue = temp - 10
          blue = 138.5177312231 * Math.log(blue) - 305.0447927307
      else
        red = temp - 60
        red = 329.698727446 * Math.pow(red, -0.1332047592)

        green = temp - 60
        green = 288.1221695283 * Math.pow(green, -0.0755148492 )

        blue = 255


      return {
        r: @clamp(red,   0, 255)
        g: @clamp(green, 0, 255)
        b: @clamp(blue,  0, 255)
      }

    clamp: (x, min, max) =>
      if x< min
        return min
      if x > max
        return max

      return x;

    # From http://stackoverflow.com/questions/2353211/hsl-to-rgb-color-conversion/9493060#9493060
    hslToRgb: (h, s, l) =>
      env.logger.debug("Hue: #{h}, sat: #{s}, l: #{l}")
      if s == 0
        r = g = b = l #achromatic
      else
        hue2rgb = (p, q, t) ->
            if t < 0
              t += 1
            if t > 1
              t -= 1
            if t < 1/6
              return p + (q - p) * 6 * t
            if t < 1/2
              return q
            if t < 2/3
              return p + (q - p) * (2/3 - t) * 6
            return p

        q = if l < 0.5 then l * (1 + s) else l + s - l * s
        p = 2 * l - q

        r = hue2rgb(p, q, h + 1/3)
        g = hue2rgb(p, q, h)
        b = hue2rgb(p, q, h - 1/3)

      return {
        r: Math.round(r * 255)
        g: Math.round(g * 255)
        b: Math.round(b * 255)
      }

    sendRequest: (method, params) =>
      if not @connection?
        return Promise.reject("Socket not initialized for #{@address}.")
      else if @connection.connecting
        return Promise.reject("The socket for #{@address} is still connecting.")
      else if @connection.destroyed
        return Promise.reject("The socket for #{@address} is destroyed.")

      id = @requestCounter++

      request = {
        id: id
        method: method
        params: params
      }
      jsonString = JSON.stringify(request)
      env.logger.debug("Sending request: #{jsonString}")
      @connection.write(jsonString + "\r\n")
      prom = new Promise((accept, reject) =>
        respond = false;
        timeout = setTimeout(() =>
          if not respond
            reject("Timeout")
        , 3000)
        @requests[id] = (res) =>
          if respond
            return
          respond = true
          error = res.error
          if error
            return reject(error)
          accept(res)
      )
      return prom

    changeDimlevelTo: (state) =>
      env.logger.debug("Current state: #{@_state}")
      # check the current state of the lightbulb
      if not @_state
        if state > 0
          # Turn on sudden and then set dimmer level accordingly
          prom = @sendRequest "set_power", ["on", "sudden", 1]
          .then (response) =>
            @sendRequest "set_bright", @getValueArray(state)
          return prom
        else
          # Do nothing
          return Promise.resolve()
      else if state == 0
         # Turn off
         return @sendRequest "set_power", @getValueArray("off")
      else
         #set State
         return @sendRequest "set_bright", @getValueArray(state)
            
    getValueArray: (args) =>
      argsArray = Array.prototype.slice.call(arguments)
      if @smoothDuration < 30
        return  argsArray.concat ["sudden", 1]
      else
         return argsArray.concat ["smooth", @smoothDuration]
          

    attributes:
      dimlevel:
        description: "the current dim level"
        type: "number"
        unit: "%"
      state:
        description: "the current state of the switch"
        type: "boolean"
        labels: ['on', 'off']
      red:
        description: "the red value of the lightbulb"
        type: "number"
      green:
        description: "the green value of the lightbulb"
        type: "number"
      blue:
        description: "the blue value of the lightbulb"
        type: "number"

    getRed: () => Promise.resolve(@red)

    getGreen: () => Promise.resolve(@green)

    getBlue: () => Promise.resolve(@blue)

    actions:
      changeDimlevelTo:
        description: "sets the level of the dimmer"
        params:
          dimlevel:
            type: "number"
      changeStateTo:
        description: "changes the switch to on or off"
        params:
          state:
            type: "boolean"
      turnOn:
        description: "turns the dim level to 100%"
      turnOff:
        description: "turns the dim level to 0%"
      setColorTemperature:
        description: "Set the color temperature of the lightbulb"
        params:
          colorTemperature:
            type: "number"
      setColorRGB:
        descriptions: "Set the rgb color of the lightbulb"
        params:
          red:
            type: "number"
          green:
            type: "number"
          blue:
            type: "number"
      setColorHSV:
        description: "Set the hsv color of the lightbulb"
        params:
          hue:
            type: "number"
          sat:
            type: "number"

    setColorTemperature: (temp) =>
      colorTemperature = Math.min(Math.max(1700, temp), 6500)
      return @sendRequest "set_ct_abx", @getValueArray(colorTemperature)

    setColorRGB: (r, g, b) =>
      env.logger.debug("Set rgb color, red: #{r}, green: #{g}, blue: #{b}")
      colorValue = r * 255 * 255 + g * 255 + b
      return @sendRequest "set_rgb", @getValueArray(colorValue)

    setColorHSV: (hue, sat) =>
      env.logger.debug("Set hsv color, hue: #{hue}, sat: #{sat}")
      return @sendRequest "set_hsv", @getValueArray(hue, sat)
  return new YeelightPlugin
