{
  lib,
  python3Packages,
  fetchFromGitHub,
}:

python3Packages.buildPythonPackage (finalAttrs: {
  pname = "pyloudnorm";
  version = "0.2.0";
  pyproject = true;

  # The sdist omits the audio fixtures required by the upstream tests.
  src = fetchFromGitHub {
    owner = "csteinmetz1";
    repo = "pyloudnorm";
    tag = "v${finalAttrs.version}";
    hash = "sha256-47CU/veoOQYv5G1QBm3F+j7ltmVvcWSY4hQWtaC6WEI=";
  };

  build-system = with python3Packages; [
    setuptools
    wheel
  ];
  dependencies = with python3Packages; [
    numpy
    scipy
  ];
  nativeCheckInputs = with python3Packages; [
    pytestCheckHook
    soundfile
  ];
  pythonImportsCheck = [ "pyloudnorm" ];

  meta = {
    description = "ITU-R BS.1770-4 loudness measurement in Python";
    homepage = "https://github.com/csteinmetz1/pyloudnorm";
    license = lib.licenses.mit;
  };
})
