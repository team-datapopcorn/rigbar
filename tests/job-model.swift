import Foundation
func expect(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
let detailed = NodeStatus(state: .online, m: ["lock":"1", "job_name":"영상 테스트", "job_stage":"자막 합성", "job_elapsed_s":"754"])
expect(detailed.lockBusy && detailed.jobTitle == "영상 테스트", "named job")
expect(detailed.jobElapsed != nil, "valid elapsed")
expect(NodeStatus(m:["job_elapsed_s":"-1"]).jobElapsed == nil, "negative elapsed")
expect(NodeStatus(m:["job_elapsed_s":"inf"]).jobElapsed == nil, "infinite elapsed")
expect(NodeStatus(m:["job_elapsed_s":"nan"]).jobElapsed == nil, "nan elapsed")
expect(NodeStatus(m:["job_folder":"folder"]).jobTitle == "folder", "legacy folder")
expect(!NodeStatus(m:["lock":"0"]).lockBusy, "idle clears badge")
expect(NodeStatus().jobElapsed == nil, "missing elapsed not fabricated")
print("8 job-model checks passed")
