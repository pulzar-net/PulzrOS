# pulzr-edge (github.com/pulzar-net/pulzr-edge), built with the SDK's Rust, as
# ChirpStack's are, so every Rust program in PulzrOS has one compiler and links
# against the image's own libc. Built for its binaries only, both from this one
# source: pulzr-edge, which feed/pulzr-edge (the add-on) packages, and
# pulzr-probe, which feed/pulzr-probe puts in every image. Their fetch scripts
# take them from here (sdk/build.sh puts them in <out>/<arch>/). The version is
# pinned here and nowhere else.

include $(TOPDIR)/rules.mk

PKG_NAME:=pulzr-edge
PKG_VERSION:=0.5.1
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/pulzar-net/pulzr-edge/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=af3ebc5d52186fa23d0c6401bfce68e3868dc4e850229c02a480e8860a279469

PKG_MAINTAINER:=Joseph Telaak <joseph@pulzr.net>
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=rust/host

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

define Package/pulzr-edge-bin
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=pulzr-edge and pulzr-probe, the binaries feed/pulzr-edge and feed/pulzr-probe package
	URL:=https://github.com/pulzar-net/pulzr-edge
	DEPENDS:=$(RUST_ARCH_DEPENDS)
endef

# One binary per module, each pulzr-edge built with that module's feature
# alone, so a gateway carries only what it runs: each capability's add-on
# ships its own (feed/pulzr-modbus pulzr-edge, feed/pulzr-zigbee
# pulzr-edge-zigbee, ...). cargo install keeps one pulzr-edge in its root, so
# each is renamed as it lands (--force, or cargo skips a package it already
# installed); Modbus's goes last and keeps the name. Bluetooth builds on
# little-endian machines only. Written out, not looped, so each is one plain
# recipe line.
NO_BLE:=$(filter mips,$(ARCH))

define Build/Compile
	$(call Build/Compile/Cargo,crates/pulzr-probe)
	$(call Build/Compile/Cargo,crates/pulzr-edge,--force --no-default-features --features zigbee)
	mv -f $(PKG_INSTALL_DIR)/bin/pulzr-edge $(PKG_INSTALL_DIR)/bin/pulzr-edge-zigbee
	$(call Build/Compile/Cargo,crates/pulzr-edge,--force --no-default-features --features zwave)
	mv -f $(PKG_INSTALL_DIR)/bin/pulzr-edge $(PKG_INSTALL_DIR)/bin/pulzr-edge-zwave
	$(call Build/Compile/Cargo,crates/pulzr-edge,--force --no-default-features --features matter)
	mv -f $(PKG_INSTALL_DIR)/bin/pulzr-edge $(PKG_INSTALL_DIR)/bin/pulzr-edge-matter
	$(call Build/Compile/Cargo,crates/pulzr-edge,--force --no-default-features --features ip)
	mv -f $(PKG_INSTALL_DIR)/bin/pulzr-edge $(PKG_INSTALL_DIR)/bin/pulzr-edge-ip
	$(if $(NO_BLE),,$(call Build/Compile/Cargo,crates/pulzr-edge,--force --no-default-features --features ble))
	$(if $(NO_BLE),true,mv -f $(PKG_INSTALL_DIR)/bin/pulzr-edge $(PKG_INSTALL_DIR)/bin/pulzr-edge-ble)
	$(call Build/Compile/Cargo,crates/pulzr-edge,--force --no-default-features --features modbus)
endef

define Package/pulzr-edge-bin/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-edge $(1)/usr/sbin/pulzr-edge
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-edge-zigbee $(1)/usr/sbin/pulzr-edge-zigbee
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-edge-zwave $(1)/usr/sbin/pulzr-edge-zwave
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-edge-matter $(1)/usr/sbin/pulzr-edge-matter
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-edge-ip $(1)/usr/sbin/pulzr-edge-ip
	$(if $(NO_BLE),,$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-edge-ble $(1)/usr/sbin/pulzr-edge-ble)
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-probe $(1)/usr/sbin/pulzr-probe
endef

$(eval $(call BuildPackage,pulzr-edge-bin))
