{
  lib,
  stdenvNoCC,
  fetchurl,
  p7zip,
  wimlib,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "winpe-image";
  version = "10.1.26100.2454";

  src = fetchurl {
    name = "adkwinpesetup-${finalAttrs.version}.exe";
    url = "https://go.microsoft.com/fwlink/?linkid=2289981";
    hash = "sha256-rfU8ohyuNoIeCo88MVRnUrnOBmlE3h1PFnPkkYMSVeI=";
  };

  nativeBuildInputs = [
    p7zip
    wimlib
  ];

  dontUnpack = true;

  installPhase = ''
    runHook preInstall
    mkdir -p $out
    cp $src $out/adkwinpesetup.exe
    runHook postInstall
  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    [ -s "$out/adkwinpesetup.exe" ]
    runHook postInstallCheck
  '';

  meta = with lib; {
    description = "Official Microsoft Windows Assessment and Deployment Kit (ADK) Windows PE Add-on";
    homepage = "https://learn.microsoft.com/en-us/windows-hardware/get-started/adk-install";
    license = licenses.unfree;
    maintainers = with maintainers; [ malix ];
    platforms = platforms.all;
  };
})
