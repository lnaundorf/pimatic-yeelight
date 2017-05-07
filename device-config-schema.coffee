module.exports ={
  title: "pimatic-yeelight device config schemas"
  YeelightBulb:
    title: "YeelightBulb config options"
    type: "object"
    extensions: ["xLink", "xAttributeOptions"]
    properties:
      address:
        description: "IP address of the light bulb"
        type: "string"
      port:
        description: "The port number of the light bulb"
        type: "number"
        default: 55443 
      smoothDuration:
        description: "The duration of the operations"
        type: "number"
        default: 500
}
