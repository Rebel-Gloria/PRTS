import ARKit

nonisolated protocol ProbeSession: AnyObject {
    func configure(delegate: any ARSessionDelegate, queue: DispatchQueue)
    func run(_ configuration: ARWorldTrackingConfiguration)
    func pause()
}

extension ARSession: ProbeSession {
    func configure(delegate: any ARSessionDelegate, queue: DispatchQueue) {
        self.delegate = delegate
        delegateQueue = queue
    }

    func run(_ configuration: ARWorldTrackingConfiguration) {
        run(configuration, options: [.resetTracking, .removeExistingAnchors])
    }
}
