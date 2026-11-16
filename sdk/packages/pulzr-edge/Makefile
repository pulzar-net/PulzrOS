# pulzr-edge (github.com/pulzar-net/pulzr-edge), built with the SDK's Rust, as
# ChirpStack's are, so every Rust program in PulzrOS has one compiler and links
# against the image's own libc. Built for its binary only: feed/pulzr-edge is
# the add-on, and its fetch takes the binary from here (sdk/build.sh puts it in
# <out>/<arch>/pulzr-edge). The version is pinned here and nowhere else.

include $(TOPDIR)/rules.mk

PKG_NAME:=pulzr-edge
PKG_VERSION:=0.3.0
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/pulzar-net/pulzr-edge/tar.gz/v$(PKG_VERSION)?
PKG_HASH:=7a828b42a9b617b6318a780dc32e4bb0eb3216fff3eebfbf8ac66df5b106fcd4

PKG_MAINTAINER:=Joseph Telaak <joseph@pulzr.net>
PKG_LICENSE:=Apache-2.0
PKG_LICENSE_FILES:=LICENSE

PKG_BUILD_DEPENDS:=rust/host

include $(INCLUDE_DIR)/package.mk
include $(TOPDIR)/feeds/packages/lang/rust/rust-package.mk

define Package/pulzr-edge-bin
	SECTION:=utils
	CATEGORY:=Utilities
	TITLE:=pulzr-edge, the binary feed/pulzr-edge packages
	URL:=https://github.com/pulzar-net/pulzr-edge
	DEPENDS:=$(RUST_ARCH_DEPENDS)
endef

define Build/Compile
	$(call Build/Compile/Cargo,crates/pulzr-edge)
endef

define Package/pulzr-edge-bin/install
	$(INSTALL_DIR) $(1)/usr/sbin
	$(INSTALL_BIN) $(PKG_INSTALL_DIR)/bin/pulzr-edge $(1)/usr/sbin/pulzr-edge
endef

$(eval $(call BuildPackage,pulzr-edge-bin))
