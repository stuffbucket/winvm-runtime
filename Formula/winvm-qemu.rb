# Derived from homebrew-core's Formula/q/qemu.rb (BSD 2-Clause License,
# Copyright (c) 2009-present, Homebrew contributors), reduced to what winvm
# uses. See README.md.
class WinvmQemu < Formula
  desc "QEMU for winvm: aarch64 system emulation with HVF, VNC and qemu-img only"
  homepage "https://github.com/stuffbucket/winvm-runtime"
  url "https://download.qemu.org/qemu-11.1.2.tar.xz"
  sha256 "731b5681e4bb18be313231579b8efd0296c5b015fa36dc533874b639ba838016"
  license "GPL-2.0-only"

  keg_only "it is winvm's private QEMU build, packaged into the winvm runtime"

  depends_on "bison" => :build
  depends_on "libtool" => :build
  depends_on "meson" => :build
  depends_on "ninja" => :build
  depends_on "pkgconf" => :build
  depends_on "python-setuptools" => :build
  depends_on "python@3.15" => :build
  depends_on arch: :arm64
  depends_on "dtc"
  depends_on "glib"
  depends_on "libgcrypt"
  depends_on "libslirp"
  depends_on macos: :sequoia
  depends_on "pixman"
  depends_on "zstd"

  uses_from_macos "flex" => :build
  uses_from_macos "zlib"

  deny_network_access!

  def install
    ENV["LIBTOOL"] = "glibtool"

    rm(Dir["python/wheels/*"] - Dir["python/wheels/{pycotap,qemu_qmp}-*-none-any.whl"])
    inreplace "pythondeps.toml", /^"wheel" = .*\n/, ""

    args = %W[
      --prefix=#{prefix}
      --cc=#{ENV.cc}
      --host-cc=#{ENV.cc}
      --target-list=aarch64-softmmu
      --disable-download
      --enable-hvf
      --enable-slirp
      --enable-fdt=system
      --enable-pixman
      --enable-vnc
      --enable-zstd
      --enable-gcrypt
      --enable-tools
      --disable-auth-pam
      --disable-bochs
      --disable-bsd-user
      --disable-bzip2
      --disable-capstone
      --disable-cloop
      --disable-cocoa
      --disable-coreaudio
      --disable-curl
      --disable-curses
      --disable-dbus-display
      --disable-dmg
      --disable-docs
      --disable-nettle
      --disable-gettext
      --disable-gnutls
      --disable-gtk
      --disable-guest-agent
      --disable-iconv
      --disable-libssh
      --disable-libusb
      --disable-lzo
      --disable-parallels
      --disable-png
      --disable-pvg
      --disable-qcow1
      --disable-qed
      --disable-replication
      --disable-sdl
      --disable-snappy
      --disable-spice
      --disable-spice-protocol
      --disable-usb-redir
      --disable-vde
      --disable-vdi
      --disable-vhdx
      --disable-virtfs
      --disable-vmdk
      --disable-vnc-jpeg
      --disable-vpc
      --disable-vvfat
    ]

    system "./configure", *args
    system "make", "V=1", "install"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/qemu-system-aarch64 --version")
    assert_match version.to_s, shell_output("#{bin}/qemu-img --version")
    devices = shell_output("#{bin}/qemu-system-aarch64 -M virt -device help")
    %w[qemu-xhci nvme virtio-blk-pci virtio-net-pci virtio-serial-pci tpm-tis-device ramfb usb-storage].each do |d|
      assert_match "\"#{d}\"", devices
    end
  end
end
