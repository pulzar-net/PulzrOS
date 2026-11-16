# Semtech's SX1302/SX1303 HAL from pulzar-net/sx1302_hal: ChirpStack's fork
# (brocaar/sx1302_hal V2.1.0r9) with the MT7628's half-duplex SPI as a build
# option. Replaces the same package in ChirpStack's feed (sdk/build.sh installs
# this one first), whose recipe this is, apart from where the source comes from
# and how the option is set: ChirpStack patches the source for ramips, this
# defines LGW_SPI_HALF_DUPLEX for it.

include $(TOPDIR)/rules.mk

PKG_NAME:=libloragw-sx1302
PKG_VERSION:=2.1.0
# ChirpStack's release number, kept: apk takes only an integer here, and this
# package never reaches a gateway (only -utils does). The source says which.
PKG_RELEASE:=9

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION)r9-hd1.tar.gz
PKG_SOURCE_URL:=https://codeload.github.com/pulzar-net/sx1302_hal/tar.gz/V$(PKG_VERSION)r9-hd1?
PKG_HASH:=a790ff805a1dd35ad835ee3a2f359c71d50d1e0b92697876ba454bb3709130f3

PKG_MAINTAINER:=Joseph Telaak <joseph@pulzr.net>
PKG_LICENSE:=BSD-3-Clause
PKG_LICENSE_FILES:=LICENSE.TXT

include $(INCLUDE_DIR)/package.mk

TAR_OPTIONS+= --strip-components 1
TAR_CMD=$(HOST_TAR) -C $(1) $(TAR_OPTIONS)
TARGET_CFLAGS:=-O2 -Wall -Wextra -std=c99 -Iinc -I. -I../libtools/inc -fPIC \
	$(if $(CONFIG_TARGET_ramips),-DLGW_SPI_HALF_DUPLEX)

define Package/libloragw-sx1302
	SECTION:=chirpstack
	CATEGORY:=ChirpStack
	TITLE:=libloragw-sx1302
	URL:=https://github.com/pulzar-net/sx1302_hal
endef

define Package/libloragw-sx1302-utils
	SECTION:=chirpstack
	CATEGORY:=ChirpStack
	TITLE:=libloragw-sx1302-utils
	URL:=https://github.com/pulzar-net/sx1302_hal
	DEPENDS:=+dfu-util
endef

define Package/libloragw-sx1302/description
	Semtech SX1302 HAL, half-duplex SPI on the MT7628.
endef

define Package/libloragw-sx1302-utils/description
	Semtech SX1302 HAL utils
endef

define Build/InstallDev
	$(INSTALL_DIR) $(STAGING_DIR)/usr/lib
	$(INSTALL_DIR) $(STAGING_DIR)/usr/include/libloragw-sx1302

	$(INSTALL_DATA) $(PKG_BUILD_DIR)/libtools/*.a $(STAGING_DIR)/usr/lib
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/libtools/inc/* $(STAGING_DIR)/usr/include

	$(INSTALL_DATA) $(PKG_BUILD_DIR)/libloragw/libloragw.a $(STAGING_DIR)/usr/lib/libloragw-sx1302.a
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/libloragw/inc/* $(STAGING_DIR)/usr/include/libloragw-sx1302
endef

define Package/libloragw-sx1302/install
	$(INSTALL_DIR) $(1)/usr/lib
	$(INSTALL_DIR) $(1)/usr/include/libloragw-sx1302

	$(INSTALL_DATA) $(PKG_BUILD_DIR)/libtools/*.a $(1)/usr/lib
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/libtools/inc/* $(1)/usr/include

	$(INSTALL_DATA) $(PKG_BUILD_DIR)/libloragw/libloragw.a $(1)/usr/lib/libloragw-sx1302.a
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/libloragw/inc/* $(1)/usr/include/libloragw-sx1302
endef

define Package/libloragw-sx1302-utils/install
	$(INSTALL_DIR) $(1)/opt/libloragw-sx1302/utils
	$(INSTALL_DIR) $(1)/opt/libloragw-sx1302/mcu_bin

	$(INSTALL_BIN) ./files/upgrade_fw.sh $(1)/opt/libloragw-sx1302/upgrade_fw.sh
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/util_boot/boot $(1)/opt/libloragw-sx1302/utils
	$(INSTALL_DATA) $(PKG_BUILD_DIR)/mcu_bin/rlz_010000_CoreCell_USB.bin $(1)/opt/libloragw-sx1302/mcu_bin
endef

$(eval $(call BuildPackage,libloragw-sx1302))
$(eval $(call BuildPackage,libloragw-sx1302-utils))
