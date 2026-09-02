abstract final class LocalSearchConfig {
  static const embeddingVersion = 'mobileclip-s0-xenova-fp16-v1';
  static const embeddingDimensions = 512;
  static const imageSide = 256;
  static const queryPipelineVersion = 'query-v4-compositional';
  static const semanticCandidates = 100;
  static const searchConfidenceThreshold = 0.22;
  static const semanticWeight = 1.0;
  static const compositionalJointWeight = 0.70;
  static const compositionalCoverageWeight = 0.30;
  static const compositionalColorCompetitionWeight = 0.10;
  static const localThumbnailSide = 256;
  static const localThumbnailQuality = 82;
  static const visionModelAsset =
      'assets/models/mobileclip_s0/vision_model_fp16.onnx';
}
