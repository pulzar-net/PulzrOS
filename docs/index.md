---
layout: home

hero:
  name: PulzrOS
  text: The gateway OS for LoRaWAN, Bluetooth and IP devices
  tagline: OpenWrt underneath. A web console, a terminal UI, signed updates and one-touch adoption on top.
  image:
    src: /icon.svg
    alt: PulzrOS
  actions:
    - theme: brand
      text: Get started
      link: /getting-started
    - theme: alt
      text: Supported hardware
      link: /hardware/
    - theme: alt
      text: View on GitHub
      link: https://github.com/pulzar-net/PulzrOS

features:
  - title: LoRaWAN gateway
    details: Concentratord and an MQTT forwarder per radio. An 8-channel Pi and a 16-channel WisGate Edge Pro run the same code; SPI, USB and UART radios are probed on kit boards.
    link: /concentrators
  - title: One-touch adoption
    details: Power on, scan the code the gateway shows, pick the organization. The gateway adopts itself and nobody types a credential into it.
    link: /provisioning
  - title: A console three ways
    details: A web console served by the gateway, and the same pages as a terminal UI over serial, SSH, HDMI and USB.
    link: /console
  - title: Backhaul that knows what it costs
    details: Ethernet, WiFi and cellular uplinks with failover. The management tunnel never rides a metered link unless you say so.
    link: /networking
  - title: Signed firmware and add-ons
    details: Every release image is Ed25519-signed and checked on the gateway before it is written. Add-ons come from a signed repository per release.
    link: /firmware
  - title: A board is a page of deltas
    details: Raspberry Pi, RAKwireless, Seeed, Dragino and GL.iNet hardware, each one board.conf over a shared configuration.
    link: /hardware/
---
