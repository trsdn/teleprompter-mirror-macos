public enum CaptureFramePolicy {
    public static func shouldDeliver(
        statusRawValue: Int?,
        hasDeliveredInitialFrame: Bool
    ) -> Bool {
        !hasDeliveredInitialFrame || statusRawValue == 0
    }
}
