
{
  ##############################################################################
  #                                     PyTorch                                #
  ##############################################################################

  # See this branch: https://github.com/pytorch/pytorch/commits/nightly
  torchVersion = "1.14.0.dev20221114"; # !!! remember to update the hashes! (below)
  torchBinHashes = {
    linux-amd64 = "sha256-TbzspWCIN1nRMCN6AluwXewkN/yJruPf4SeTvtve+Do=";
    darwin-aarch64 = "";
  };
  torchSha = "b7c4176df3a734ad040c604c500d1a57e12d9083"; # !!! remember to update the hash! (below)
  torchSrcHash = "sha256-muXwqtZ7RjDbiIcIRP0rDjOC4C1YViwjFFV5C3sGcp0=";

  # See this branch: https://github.com/pytorch/vision/commits/nightly
  torchvisionVersion = "0.15.0.dev20221114"; # !!! remember to update the hashes! (below)
  torchvisionBinHashes = {
    linux-amd64 = "sha256-wjjH8fml/ZEHg4wUEx251ymBmANPt/TpFBUB3D82ki8=";
    darwin-aarch64 = "";
  };
  torchvisionSha = "fe67dcf26876906a02bd4fe6328dde643be5364e"; # !!! remember to update the hash! (below)
  torchvisionSrcHash = "sha256-BnpJo/8A1zgn9v7X6cP8b11JPsFVH5FsfiobHASuye8=";

}

# TODO: make overridable
