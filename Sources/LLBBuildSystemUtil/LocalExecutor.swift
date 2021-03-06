// This source file is part of the Swift.org open source project
//
// Copyright (c) 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See http://swift.org/LICENSE.txt for license information
// See http://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import llbuild2
import LLBBuildSystemProtocol
import LLBCASFileTree
import TSCBasic

public enum LLBLocalExecutorError: Error {
    case unimplemented(String)
    case unexpected(Error)
    case missingInput(LLBActionInput)
    case preActionFailure(String)
}

/// Simple local executor that uses the host machine's resources to execute actions.
final public class LLBLocalExecutor: LLBExecutor {
    let outputBase: AbsolutePath

    public init(outputBase: AbsolutePath) {
        self.outputBase = outputBase
    }

    public func execute(request: LLBActionExecutionRequest, engineContext: LLBBuildEngineContext) -> LLBFuture<LLBActionExecutionResponse> {
        var inputFutures = [LLBFuture<Void>]()
        let client = LLBCASFSClient(engineContext.db)

        for input in request.inputs {
            // Create the parent directory for each of the inputs, so that they can be exported there.
            let fullInputPath = outputBase.appending(RelativePath(input.path))
            do {
                try localFileSystem.createDirectory(fullInputPath.parentDirectory, recursive: true)
            } catch {
                return engineContext.group.next().makeFailedFuture(error)
            }

            // This is a local optimization, if the file has already been exported, don't export it again. Because
            // we're not supporting incremental builds locally (by creating a new output base for each invocation) we're
            // not running a risk of the files having other contents. This assumes that the paths for all artifacts
            // in a build are unique, i.e. there are no 2 artifacts that share the same path.
            if !localFileSystem.exists(fullInputPath) {
                if input.type == .directory {
                    inputFutures.append(
                        LLBCASFileTree.export(
                            LLBDataID(input.dataID),
                            from: engineContext.db,
                            to: .init(fullInputPath.pathString)
                        )
                    )
                } else {
                    inputFutures.append(
                        client.load(LLBDataID(input.dataID)).flatMap { (node: LLBCASFSNode) -> LLBFuture<(LLBByteBufferView, LLBFileType)> in
                            guard let blob = node.blob else {
                                return engineContext.group.next().makeFailedFuture(LLBLocalExecutorError.missingInput(input))
                            }
                            return blob.read().map { ($0, node.type()) }
                        }.flatMapThrowing { (data, type) in
                            try localFileSystem.writeFileContents(fullInputPath, bytes: ByteString(data))
                            if type == .executable {
                                try localFileSystem.chmod(.executable, path: fullInputPath)
                            }
                        }
                    )
                }
            }
        }

        return LLBFuture.whenAllSucceed(inputFutures, on: engineContext.group.next()).flatMapThrowing { _ in
            // For each of the declared outputs, make sure that the parent directory exists.
            for output in request.outputs {
                try localFileSystem.createDirectory(
                    self.outputBase.appending(RelativePath(output.path)).parentDirectory,
                    recursive: true
                )
            }
        }.flatMapThrowing { _ -> (Int, [UInt8], [UInt8]) in
            let environment = request.actionSpec.environment.reduce(into: [String: String]()) { (dict, pair) in
                dict[pair.name] = pair.value
            }

            // Execute the pre-actions of the request.
            for preActionSpec in request.actionSpec.preActions {
                let preActionEnvironment = preActionSpec.environment.reduce(into: environment) { (dict, pair) in
                    dict[pair.name] = pair.value
                }

                let preActionProcess = TSCBasic.Process(
                    arguments: preActionSpec.arguments,
                    environment: preActionEnvironment,
                    workingDirectory: self.outputBase.appending(RelativePath(request.actionSpec.workingDirectory)),
                    outputRedirection: .collect,
                    verbose: false,
                    startNewProcessGroup: false
                )

                try preActionProcess.launch()

                if preActionSpec.background {
                    throw LLBLocalExecutorError.unimplemented("preAction background mode is not yet implemented.")
                } else {
                    // If the pre-action is not in background mode, wait until it finishes.
                    let result = try preActionProcess.waitUntilExit()
                    guard case .terminated(code: let code) = result.exitStatus, code == 0 else {
                        throw LLBLocalExecutorError.preActionFailure(try result.utf8stderrOutput())
                    }
                }
            }

            // Execute the main action of the request.
            let process = TSCBasic.Process(
                arguments: request.actionSpec.arguments,
                environment: environment,
                workingDirectory: self.outputBase.appending(RelativePath(request.actionSpec.workingDirectory)),
                outputRedirection: .collect,
                verbose: false,
                startNewProcessGroup: false
            )

            try process.launch()
            let result = try process.waitUntilExit()

            let resultExitCode: Int
            switch result.exitStatus {
            case .terminated(let code):
                resultExitCode = Int(code)
            case .signalled(_):
                resultExitCode = -1
            }

            return (resultExitCode, try result.output.get(), try result.stderrOutput.get())
        }.flatMap { (exitCode, stdout, stderr) in
            // Upload the stdout and stderr of the action into the CAS.
            let stdoutFuture = engineContext.db.put(data: .withBytes(stdout[...]))
            let stderrFuture = engineContext.db.put(data: .withBytes(stderr[...]))

            let uploadFutures: [LLBFuture<LLBDataID>]

            // Only upload outputs if the action exited successfully.
            if exitCode == 0 {
                uploadFutures = request.outputs.map { output in
                    let outputPath = self.outputBase.appending(RelativePath(output.path))
                    if output.type == .directory {
                        return LLBCASFileTree.import(path: outputPath, to: engineContext.db).flatMapError { error in
                            if case FileSystemError.noEntry = error {
                                // If we didn't find an output artifact that was a directory, create an empty CASTree to
                                // represent it.
                                return LLBCASFileTree.create(files: [], in: engineContext.db).map { $0.id }
                            }
                            return engineContext.group.next().makeFailedFuture(error)
                        }
                    } else {
                        var dataIDFuture: LLBFuture<LLBDataID>! = nil
                        do {
                            try localFileSystem.readFileContents(outputPath).withData { fileData in
                                dataIDFuture = client.store(ArraySlice<UInt8>(fileData), type: .plainFile)
                            }
                        } catch {
                            return engineContext.group.next().makeFailedFuture(error)
                        }
                        return dataIDFuture
                    }
                }
            } else {
                uploadFutures = []
            }

            let uploadsFuture = LLBFuture.whenAllSucceed(uploadFutures, on: engineContext.group.next())

            return stdoutFuture.and(stderrFuture).and(uploadsFuture).map { stdouterrIDs, outputUploads in
                return LLBActionExecutionResponse(
                    outputs: outputUploads.map { LLBPBDataID($0) },
                    exitCode: exitCode,
                    stdoutID: LLBPBDataID(stdouterrIDs.0),
                    stderrID: LLBPBDataID(stdouterrIDs.1)
                )
            }
        }.flatMapErrorThrowing { error in
            // If we found any errors that were not LLBExecutorError, convert them into an LLBExecutorError.
            if error is LLBLocalExecutor {
                throw error
            }
            throw LLBLocalExecutorError.unexpected(error)
        }
    }
}
