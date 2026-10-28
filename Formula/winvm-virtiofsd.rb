# virtiofsd for winvm: the vhost-user virtio-fs daemon that serves a Mac
# folder to the Windows guest (vhost-user-fs-pci). Upstream virtiofsd is
# Linux-only; this is Chris Thomas's macOS port, pinned by commit (v1.14.0).
# It patches three rust-vmm crates (vhost, vhost-user-backend, vmm-sys-util)
# from forks; its Cargo.lock pins each fork by commit, and the build is
# --locked, so the build does not follow those branches. See README.md.
class WinvmVirtiofsd < Formula
  desc "virtiofsd for winvm: vhost-user virtio-fs daemon (macOS port)"
  homepage "https://github.com/christhomas/virtiofsd"
  url "https://github.com/christhomas/virtiofsd/archive/a3a1b15ba0d04640c77de0b57ac015fdedec7746.tar.gz"
  version "1.14.0"
  sha256 "66dcbaab6b946001c10cb0617e47a3afe0ad22b41779cbb9fce54923296c4f41"
  license all_of: ["Apache-2.0", "BSD-3-Clause"]

  keg_only "it is winvm's private virtiofsd build, packaged into the winvm runtime"

  depends_on "rust" => :build
  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    # Vendor every crate first (the forks included, at their locked commits),
    # then build offline from the vendored tree: what is built is exactly what
    # Cargo.lock names, and the crates' licence files are at hand below.
    config = Utils.safe_popen_read("cargo", "vendor", "--locked", "--versioned-dirs", "vendor")
    (buildpath/".cargo/config.toml").write config
    system "cargo", "build", "--release", "--locked", "--offline", "--bin", "virtiofsd"
    bin.install "target/release/virtiofsd"

    # A Rust binary carries its crates statically, so their notices ship too.
    licenses = share/"licenses/virtiofsd"
    licenses.install "LICENSE-APACHE", "LICENSE-BSD-3-Clause"
    meta = JSON.parse(Utils.safe_popen_read("cargo", "metadata", "--locked", "--offline", "--format-version", "1"))
    crates = meta["packages"].map { |p| "#{p["name"]} #{p["version"]} #{p["license"] || "(see crates/)"}" }.sort
    (licenses/"crates.txt").write "#{crates.join("\n")}\n"
    Dir["vendor/*"].sort.each do |dir|
      files = Dir["#{dir}/{LICENSE,LICENCE,COPYING,NOTICE,COPYRIGHT}*"].select { |f| File.file?(f) }
      (licenses/"crates"/File.basename(dir)).install files unless files.empty?
    end
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/virtiofsd --version")
    assert_match "--readonly", shell_output("#{bin}/virtiofsd --help")
    assert_path_exists share/"licenses/virtiofsd/LICENSE-APACHE"
  end
end
