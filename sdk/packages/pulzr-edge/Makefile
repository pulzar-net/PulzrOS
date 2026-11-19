# pulzr-edge (github.com/pulzar-net/pulzr-edge), built with the SDK's Rust, as
# ChirpStack's are, so every Rust program in PulzrOS has one compiler and links
# against the image's own libc. Built for its binaries only, both from this one
# source: pulzr-edge, which feed/pulzr-edge (the add-on) packages, and
# pulzr-probe, which feed/pulzr-probe puts in every image. Their fetch scripts
# take them from here (sdk/build.sh puts them in <out>/<arch>/). The version is
# pinned here and nowhere else.

include $(TOPDIR)/rules.mk

PKG_NAME:=pulzr-edge
PKG_VERSION:=0.4.1
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/pulzar-net/pulzr-edge/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=fec1039c4c75d48bd8488722f4b192107fb5169c2820eedd02d1c11eba1762ad

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

define Build/Compile
	$(call Build/Compile/Cargo,crates/pulzr-edge)
	$(call Build/Compile/Cargo,crates/pulzr-probe)
endef

define Package/pulzr-edge-bin/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-edge $(1)/usr/sbin/pulzr-edge
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-probe $(1)/usr/sbin/pulzr-probe
endef

$(eval $(call BuildPackage,pulzr-edge-bin))
