#!/usr/bin/env bash
set -euo pipefail

# Builds a NativeScript-compatible Hermes xcframework from facebook/hermes
# commit eb461d8, while attempting to keep both:
# - static Hermes enabled
# - Node-API support enabled
#
# Important:
# Upstream facebook/hermes at eb461d8 does not ship Node-API support.
# This script forward-ports the latest public Node-API layer from
# https://github.com/kraenhansen/hermes and then applies extra compatibility
# edits needed for newer upstream APIs.

UPSTREAM_URL="${UPSTREAM_URL:-https://github.com/facebook/hermes.git}"
UPSTREAM_COMMIT="${UPSTREAM_COMMIT:-eb461d844d69853cd12de4b0af7b271dcfbb085a}"
NODE_API_DONOR_URL="${NODE_API_DONOR_URL:-https://github.com/kraenhansen/hermes.git}"
NODE_API_DONOR_REF="${NODE_API_DONOR_REF:-node-api-hermes-2025-09-01-RNv0.82.0-265ef62ff3eb7289d17e366664ac0da82303e101}"

WORK_ROOT="${WORK_ROOT:-$PWD/.hermes-eb461d8-node-api}"
SRC_DIR="${SRC_DIR:-$WORK_ROOT/src}"
IOS_NEXT_DIR="${IOS_NEXT_DIR:-$HOME/Developer/Projects/NativeScript/ios-next}"
OUTPUT_XCFRAMEWORK="${OUTPUT_XCFRAMEWORK:-$IOS_NEXT_DIR/Frameworks/hermes.xcframework}"
OUTPUT_HEADERS_DIR="${OUTPUT_HEADERS_DIR:-$(dirname "$OUTPUT_XCFRAMEWORK")/hermes-headers}"
OUTPUT_TOOLS_DIR="${OUTPUT_TOOLS_DIR:-$(dirname "$OUTPUT_XCFRAMEWORK")/hermes-tools-macos}"

IOS_DEPLOYMENT_TARGET="${IOS_DEPLOYMENT_TARGET:-13.0}"
MAC_DEPLOYMENT_TARGET="${MAC_DEPLOYMENT_TARGET:-11.0}"
BUILD_TYPE="${BUILD_TYPE:-Release}"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

note() {
  printf '\n==> %s\n' "$*"
}

require_cmd git
require_cmd cmake
require_cmd xcodebuild
require_cmd plutil
require_cmd python3
require_cmd rsync

mkdir -p "$WORK_ROOT"

if [[ ! -d "$SRC_DIR/.git" ]]; then
  note "Cloning upstream Hermes"
  git clone "$UPSTREAM_URL" "$SRC_DIR"
fi

note "Fetching upstream commit and Node-API donor ref"
git -C "$SRC_DIR" fetch origin
git -C "$SRC_DIR" fetch "$NODE_API_DONOR_URL" "$NODE_API_DONOR_REF"

note "Checking out upstream commit"
git -C "$SRC_DIR" reset --hard "$UPSTREAM_COMMIT"
git -C "$SRC_DIR" clean -fdx

note "Importing Node-API sources from donor ref"
git -C "$SRC_DIR" checkout FETCH_HEAD -- \
  API/hermes_node_api \
  unittests/API/NodeAPITest.cpp

note "Applying forward-port compatibility edits"
python3 - <<'PY' "$SRC_DIR"
from pathlib import Path
import sys

root = Path(sys.argv[1])

def replace_once(path: Path, old: str, new: str):
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"Expected snippet not found in {path}: {old[:80]!r}")
    path.write_text(text.replace(old, new, 1))

def replace_all(path: Path, old: str, new: str):
    text = path.read_text()
    if old not in text:
        raise SystemExit(f"Expected snippet not found in {path}: {old[:80]!r}")
    path.write_text(text.replace(old, new))

api_cmake = root / "API/CMakeLists.txt"
replace_once(
    api_cmake,
    'add_subdirectory(hermes_abi)\nadd_subdirectory(hermes_sandbox)\n',
    'add_subdirectory(hermes_abi)\nadd_subdirectory(hermes_node_api)\nadd_subdirectory(hermes_sandbox)\n',
)

hermes_cmake = root / "API/hermes/CMakeLists.txt"
replace_once(
    hermes_cmake,
    'target_include_directories(hermesapi_obj PUBLIC ..)\n',
    'target_include_directories(hermesapi_obj PUBLIC ..)\n'
    'target_include_directories(\n'
    '  hermesapi_obj\n'
    '  PRIVATE\n'
    '  ${PROJECT_SOURCE_DIR}/API/hermes_node_api\n'
    '  ${PROJECT_SOURCE_DIR}/API/hermes_node_api/node_api\n'
    ')\n',
)

lib_cmake = root / "lib/CMakeLists.txt"
replace_once(
    lib_cmake,
    '  ${BOOST_CONTEXT_LIB}\n  dtoa_obj\n  hermesapi_obj\n',
    '  ${BOOST_CONTEXT_LIB}\n  dtoa_obj\n  hermesNodeApi\n  hermesapi_obj\n',
)
replace_once(
    lib_cmake,
    "if (HERMES_BUILD_SHARED_JSI)\n  target_link_libraries(hermesvm PUBLIC jsi)\nendif()\n",
    "if (HERMES_BUILD_SHARED_JSI)\n  target_link_libraries(hermesvm PUBLIC jsi)\nendif()\n"
    "\n"
    "if(APPLE)\n"
    "  target_link_libraries(hermesvm PRIVATE ${FOUNDATION} ${CORE_FOUNDATION})\n"
    "  target_link_libraries(hermesvmlean PRIVATE ${FOUNDATION} ${CORE_FOUNDATION})\n"
    "endif()\n",
)

jsi_h = root / "API/jsi/jsi/jsi.h"
replace_once(
    jsi_h,
    '  std::shared_ptr<void> getRuntimeData(const UUID& uuid) override;\n',
    '  std::shared_ptr<void> getRuntimeData(const UUID& uuid) override;\n'
    '\n'
    '  /// Creates a Node-API environment.\n'
    '  /// \\throw a \\c JSINativeException if the runtime does not support Node-API.\n'
    '  /// \\param apiVersion the version of Node-API to use.\n'
    '  /// \\return the newly created Node-API environment.\n'
    '  virtual void* createNodeApiEnv(int32_t apiVersion);\n',
)

jsi_cpp = root / "API/jsi/jsi/jsi.cpp"
replace_once(
    jsi_cpp,
    "  static NoInstrumentation sharedInstance;\n"
    "  return sharedInstance;\n"
    "}\n"
    "\n"
    "Value Runtime::createValueFromJsonUtf8(const uint8_t* json, size_t length) {\n",
    "  static NoInstrumentation sharedInstance;\n"
    "  return sharedInstance;\n"
    "}\n"
    "\n"
    "void* Runtime::createNodeApiEnv(int32_t apiVersion) {\n"
    "  throw JSINativeException(\n"
    "      \"Node-API is not supported by this particular JSI runtime\");\n"
    "}\n"
    "\n"
    "Value Runtime::createValueFromJsonUtf8(const uint8_t* json, size_t length) {\n",
)

hermes_cpp = root / "API/hermes/hermes.cpp"
replace_once(
    hermes_cpp,
    '#include <jsi/threadsafe.h>\n',
    '#include <jsi/threadsafe.h>\n'
    '\n'
    '#ifndef HERMESVM_LEAN\n'
    '#include <hermes_node_api/hermes_node_api.h>\n'
    '#endif\n',
)
replace_once(
    hermes_cpp,
    '  std::string description() override;\n'
    '  bool isInspectable() override;\n'
    '  jsi::Instrumentation &instrumentation() override;\n',
    '  std::string description() override;\n'
    '  bool isInspectable() override;\n'
    '  jsi::Instrumentation &instrumentation() override;\n'
    '  void *createNodeApiEnv(int32_t apiVersion) override;\n',
)
replace_once(
    hermes_cpp,
    "  throwPendingError();\n"
    "}\n"
    "\n"
    "namespace {\n",
    "  throwPendingError();\n"
    "}\n"
    "\n"
    "void *HermesRuntimeImpl::createNodeApiEnv(int32_t apiVersion) {\n"
    "#ifndef HERMESVM_LEAN\n"
    "  auto res = ::hermes::node_api::createModuleNodeApiEnvironment(\n"
    "      *static_cast<vm::Runtime *>(this->getVMRuntimeUnsafe()), apiVersion);\n"
    "  if (res.getStatus() == ::hermes::vm::ExecutionStatus::EXCEPTION) {\n"
    "    throw std::runtime_error(\"Failed to create Node API environment\");\n"
    "  }\n"
    "  return res.getValue();\n"
    "#else\n"
    "  (void)apiVersion;\n"
    "  return nullptr;\n"
    "#endif\n"
    "}\n"
    "\n"
    "namespace {\n",
)

hermes_node_api = root / "API/hermes_node_api/hermes_node_api.cpp"
replace_once(
    hermes_node_api,
    '#include "hermes/BCGen/HBC/BytecodeProviderFromSrc.h"\n',
    '#include "hermes/BCGen/HBC/BCProviderFromSrc.h"\n',
)

for name in (
    "Promise",
    "allRejections",
    "code",
    "hostFunction",
    "onHandled",
    "onUnhandled",
    "reject",
    "resolve",
):
    replace_once(
        hermes_node_api,
        f'registerLazyIdentifier(\n              vm::createASCIIRef("{name}"))',
        f'registerLazyIdentifier(\n              runtime_,\n              vm::createASCIIRef("{name}"))',
    )

replace_once(
    hermes_node_api,
    "      const vm::PinnedHermesValue &errorPrototype,\n",
    "      vm::Handle<vm::JSObject> errorPrototype,\n",
)
replace_once(
    hermes_node_api,
    "      const vm::PinnedHermesValue &prototype,\n",
    "      vm::Handle<vm::JSObject> prototype,\n",
)
replace_once(
    hermes_node_api,
    "  vm::CallResult<vm::Handle<vm::BigStorage>> keyStorage =\n",
    "  vm::CallResult<vm::Handle<vm::ArrayStorageSmall>> keyStorage =\n",
)
replace_once(
    hermes_node_api,
    "  vm::CallResult<vm::MutableHandle<vm::BigStorage>> keyStorageRes =\n"
    "      makeMutableHandle(vm::BigStorage::create(runtime_, 16));\n",
    "  vm::CallResult<vm::HermesValue> keyStorageValueRes =\n"
    "      vm::ArrayStorageSmall::create(runtime_, 16);\n"
    "  CHECK_NAPI(checkJSErrorStatus(keyStorageValueRes));\n"
    "  vm::MutableHandle<vm::ArrayStorageSmall> keyStorageRes{\n"
    "      runtime_, vm::vmcast<vm::ArrayStorageSmall>(*keyStorageValueRes)};\n",
)
replace_once(
    hermes_node_api,
    "        vm::MutableHandle<vm::SymbolID> tmpSymbolStorage{runtime_};\n"
    "        vm::ComputedPropertyDescriptor desc;\n"
    "        vm::CallResult<bool> hasDescriptorRes =\n"
    "            vm::JSObject::getOwnComputedPrimitiveDescriptor(\n"
    "                currentObj,\n"
    "                runtime_,\n"
    "                prop,\n"
    "                vm::JSObject::IgnoreProxy::No,\n"
    "                tmpSymbolStorage,\n"
    "                desc);\n",
    "        vm::ComputedPropertyDescriptor desc;\n"
    "        vm::CallResult<bool> hasDescriptorRes =\n"
    "            vm::JSObject::getOwnComputedPrimitiveDescriptor(\n"
    "                currentObj,\n"
    "                runtime_,\n"
    "                prop,\n"
    "                vm::JSObject::IgnoreProxy::No,\n"
    "                desc);\n",
)
replace_once(
    hermes_node_api,
    "          vm::BigStorage::push_back(*keyStorageRes, runtime_, prop)));\n",
    "          vm::ArrayStorageSmall::push_back(keyStorageRes, runtime_, prop)));\n",
)
replace_once(
    hermes_node_api,
    "  vm::CallResult<vm::Handle<vm::JSArray>> res =\n"
    "      vm::JSArray::create(runtime_, length, length);\n"
    "  CHECK_NAPI(checkJSErrorStatus(res));\n"
    "  vm::Handle<vm::JSArray> array = *res;\n",
    "  vm::CallResult<vm::PseudoHandle<vm::JSArray>> res =\n"
    "      vm::JSArray::create(runtime_, length, length);\n"
    "  CHECK_NAPI(checkJSErrorStatus(res));\n"
    "  vm::Handle<vm::JSArray> array = makeHandle(std::move(*res));\n",
)
replace_once(
    hermes_node_api,
    "      key = makeHandle(keyStorage->at(runtime_, startIndex + i));\n",
    "      key = runtime_.makeHandle(\n"
    "          keyStorage->at(startIndex + i).unboxToHV(runtime_));\n",
)
replace_once(
    hermes_node_api,
    "      vm::JSArray::setElementAt(array, runtime_, i, key);\n",
    "      CHECK_NAPI(checkJSErrorStatus(\n"
    "          vm::JSArray::setElementAt(array, runtime_, i, key)));\n",
)
replace_once(
    hermes_node_api,
    "              keyStorage->at(runtime_, startIndex + i), runtime_));\n",
    "              keyStorage->at(startIndex + i).unboxToHV(runtime_), runtime_));\n",
)
replace_once(
    hermes_node_api,
    "      vm::JSArray::setElementAt(array, runtime_, i, strKey);\n",
    "      CHECK_NAPI(checkJSErrorStatus(\n"
    "          vm::JSArray::setElementAt(array, runtime_, i, strKey)));\n",
)
replace_once(
    hermes_node_api,
    "      vm::Handle<vm::BigStorage> keyStorage,\n",
    "      vm::Handle<vm::ArrayStorageSmall> keyStorage,\n",
)
replace_once(
    hermes_node_api,
    "napi_status NodeApiEnvironment::convertKeyStorageToArray(\n"
    "    vm::Handle<vm::BigStorage> keyStorage,\n",
    "napi_status NodeApiEnvironment::convertKeyStorageToArray(\n"
    "    vm::Handle<vm::ArrayStorageSmall> keyStorage,\n",
)

replace_once(
    hermes_node_api,
    "    const vm::PinnedHermesValue &errorPrototype,\n",
    "    vm::Handle<vm::JSObject> errorPrototype,\n",
)
replace_once(
    hermes_node_api,
    "  vm::Handle<vm::JSError> errorHandle = makeHandle(\n"
    "      vm::JSError::create(runtime_, makeHandle<vm::JSObject>(&errorPrototype)));\n",
    "  vm::Handle<vm::JSError> errorHandle =\n"
    "      makeHandle(vm::JSError::create(runtime_, errorPrototype));\n",
)
replace_once(
    hermes_node_api,
    "  return createJSError(runtime_.ErrorPrototype, code, message, result);\n",
    "  return createJSError(\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.ErrorPrototype),\n"
    "      code,\n"
    "      message,\n"
    "      result);\n",
)
replace_once(
    hermes_node_api,
    "  return createJSError(runtime_.TypeErrorPrototype, code, message, result);\n",
    "  return createJSError(\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.TypeErrorPrototype),\n"
    "      code,\n"
    "      message,\n"
    "      result);\n",
)
replace_once(
    hermes_node_api,
    "  return createJSError(runtime_.RangeErrorPrototype, code, message, result);\n",
    "  return createJSError(\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.RangeErrorPrototype),\n"
    "      code,\n"
    "      message,\n"
    "      result);\n",
)

replace_once(
    hermes_node_api,
    "    const vm::PinnedHermesValue &prototype,\n",
    "    vm::Handle<vm::JSObject> prototype,\n",
)
replace_once(
    hermes_node_api,
    "  vm::Handle<vm::JSError> errorHandle = makeHandle(\n"
    "      vm::JSError::create(runtime_, makeHandle<vm::JSObject>(&prototype)));\n",
    "  vm::Handle<vm::JSError> errorHandle =\n"
    "      makeHandle(vm::JSError::create(runtime_, prototype));\n",
)
replace_once(
    hermes_node_api,
    "  return throwJSError(runtime_.ErrorPrototype, code, message);\n",
    "  return throwJSError(\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.ErrorPrototype),\n"
    "      code,\n"
    "      message);\n",
)
replace_once(
    hermes_node_api,
    "  return throwJSError(runtime_.TypeErrorPrototype, code, message);\n",
    "  return throwJSError(\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.TypeErrorPrototype),\n"
    "      code,\n"
    "      message);\n",
)
replace_once(
    hermes_node_api,
    "  return throwJSError(runtime_.RangeErrorPrototype, code, message);\n",
    "  return throwJSError(\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.RangeErrorPrototype),\n"
    "      code,\n"
    "      message);\n",
)

replace_once(
    hermes_node_api,
    "  static vm::CallResult<vm::HermesValue>\n  func(void *context, vm::Runtime &runtime, vm::NativeArgs hvArgs);\n",
    "  static vm::CallResult<vm::HermesValue> func(\n"
    "      void *context,\n"
    "      vm::Runtime &runtime);\n",
)
replace_once(
    hermes_node_api,
    "/*static*/ vm::CallResult<vm::HermesValue> NodeApiHostFunctionContext::func(\n"
    "    void *context,\n"
    "    vm::Runtime &runtime,\n"
    "    vm::NativeArgs hvArgs) {\n",
    "/*static*/ vm::CallResult<vm::HermesValue> NodeApiHostFunctionContext::func(\n"
    "    void *context,\n"
    "    vm::Runtime &runtime) {\n",
)
replace_once(
    hermes_node_api,
    "  NodeApiHandleScope scope{env};\n",
    "  vm::NativeArgs hvArgs = runtime.getCurrentFrame().getNativeArgs();\n"
    "  NodeApiHandleScope scope{env};\n",
)

replace_once(
    hermes_node_api,
    "  vm::CallResult<vm::PseudoHandle<vm::JSObject>> thisRes =\n"
    "      vm::Callable::createThisForConstruct_RJS(ctorHandle, runtime_);\n",
    "  vm::CallResult<vm::PseudoHandle<>> thisRes =\n"
    "      vm::Callable::createThisForConstruct_RJS(ctorHandle, runtime_, ctorHandle);\n",
)

replace_once(
    hermes_node_api,
    "  vm::PseudoHandle<vm::NativeConstructor> ctorRes =\n"
    "      vm::NativeConstructor::create(\n"
    "          runtime_,\n"
    "          parentHandle,\n"
    "          context.get(),\n"
    "          &NodeApiHostFunctionContext::func,\n"
    "          /*paramCount:*/ 0,\n"
    "          vm::NativeConstructor::creatorFunction<vm::JSObject>,\n"
    "          vm::CellKind::JSObjectKind);\n",
    "  vm::PseudoHandle<vm::NativeConstructor> ctorRes =\n"
    "      vm::NativeConstructor::create(\n"
    "          runtime_,\n"
    "          parentHandle,\n"
    "          context.get(),\n"
    "          &NodeApiHostFunctionContext::func,\n"
    "          /*paramCount:*/ 0);\n",
)
replace_once(
    hermes_node_api,
    "      prototypeHandle,\n"
    "      vm::Callable::WritablePrototype::Yes,\n"
    "      /*strictMode*/ false);\n",
    "      prototypeHandle,\n"
    "      vm::Callable::WritablePrototype::Yes);\n",
)

replace_once(
    hermes_node_api,
    "  const uint8_t *tagBufferData = tagBuffer->getDataBlock(runtime_);\n",
    "  const uint8_t *tagBufferData = tagBuffer->getDataBlock();\n",
)
replace_once(
    hermes_node_api,
    "          makeHandle<vm::JSObject>(&runtime_.objectPrototype),\n",
    "          vm::Handle<vm::JSObject>::vmcast(&runtime_.objectPrototype),\n",
)
replace_all(
    hermes_node_api,
    "sentinelTag.isNativeValue()",
    "sentinelTag.isDouble()",
)
replace_once(
    hermes_node_api,
    "      runtime_, makeHandle<vm::JSObject>(runtime_.arrayBufferPrototype)));\n",
    "      runtime_, vm::Handle<vm::JSObject>::vmcast(&runtime_.arrayBufferPrototype)));\n",
)
replace_once(
    hermes_node_api,
    "      runtime_, makeHandle<vm::JSObject>(&runtime_.arrayBufferPrototype)));\n",
    "      runtime_, vm::Handle<vm::JSObject>::vmcast(&runtime_.arrayBufferPrototype)));\n",
)
replace_all(
    hermes_node_api,
    "getDataBlock(runtime_)",
    "getDataBlock()",
)
replace_once(
    hermes_node_api,
    "  return checkJSErrorStatus(vm::JSArrayBuffer::detach(runtime_, buffer));\n",
    "  vm::JSArrayBuffer::detach(runtime_, buffer);\n"
    "  return clearLastNativeError();\n",
)

replace_once(
    hermes_node_api,
    "    std::unique_ptr<NodeApiExternalBuffer> externalBuffer =\n"
    "        std::make_unique<NodeApiExternalBuffer>(\n"
    "            env, externalData, byteLength, finalizeCallback, finalizeHint);\n"
    "    vm::JSArrayBuffer::setExternalDataBlock(\n"
    "        runtime_,\n"
    "        buffer,\n"
    "        reinterpret_cast<uint8_t *>(externalData),\n"
    "        byteLength,\n"
    "        externalBuffer.release(),\n"
    "        [](vm::GC & /*gc*/, vm::NativeState *ns) {\n"
    "          std::unique_ptr<NodeApiExternalBuffer> externalBuffer(\n"
    "              reinterpret_cast<NodeApiExternalBuffer *>(ns->context()));\n"
    "        });\n",
    "    std::shared_ptr<void> externalBuffer(\n"
    "        NodeApiExternalBuffer::make(\n"
    "            napiEnv(this),\n"
    "            externalData,\n"
    "            byteLength,\n"
    "            finalizeCallback,\n"
    "            finalizeHint)\n"
    "            .release(),\n"
    "        [](void *ptr) {\n"
    "          delete reinterpret_cast<NodeApiExternalBuffer *>(ptr);\n"
    "        });\n"
    "    vm::JSArrayBuffer::setExternalDataBlock(\n"
    "        runtime_,\n"
    "        buffer,\n"
    "        reinterpret_cast<uint8_t *>(externalData),\n"
    "        byteLength,\n"
    "        externalBuffer);\n",
)

replace_once(
    hermes_node_api,
    "  CHECK_NAPI(checkJSErrorStatus(keyStorageRes));\n",
    "",
)
replace_once(
    hermes_node_api,
    "  return scope.setResult(\n"
    "      convertKeyStorageToArray(*keyStorageRes, 0, size, keyConversion, result));\n",
    "  return scope.setResult(\n"
    "      convertKeyStorageToArray(keyStorageRes, 0, size, keyConversion, result));\n",
)
replace_once(
    hermes_node_api,
    "      vm::CallResult<vm::HermesValue> propRes =\n"
    "          vm::PropertyAccessor::create(runtime_, localGetter, localSetter);\n"
    "      CHECK_NAPI(checkJSErrorStatus(propRes));\n"
    "      CHECK_NAPI(defineOwnProperty(\n"
    "          objHandle, *name, dpFlags, makeHandle(*propRes), nullptr));\n",
    "      auto propRes = vm::PropertyAccessor::create(\n"
    "          runtime_, localGetter, localSetter);\n"
    "      CHECK_NAPI(defineOwnProperty(\n"
    "          objHandle,\n"
    "          *name,\n"
    "          dpFlags,\n"
    "          runtime_.makeHandle(std::move(propRes)),\n"
    "          nullptr));\n",
)
replace_once(
    hermes_node_api,
    "  vm::CallResult<vm::PseudoHandle<>> thisRes =\n"
    "      vm::Callable::createThisForConstruct_RJS(ctorHandle, runtime_, ctorHandle);\n"
    "  CHECK_NAPI(checkJSErrorStatus(thisRes));\n"
    "  // We need to capture this in case the ctor doesn't return an object,\n"
    "  // we need to return this object.\n"
    "  vm::Handle<vm::JSObject> thisHandle = makeHandle(std::move(*thisRes));\n",
    "  auto thisRes =\n"
    "      vm::Callable::createThisForConstruct_RJS(ctorHandle, runtime_, ctorHandle);\n"
    "  CHECK_NAPI(checkJSErrorStatus(thisRes));\n"
    "  // We need to capture this in case the ctor doesn't return an object,\n"
    "  // we need to return this object.\n"
    "  vm::Handle<vm::JSObject> thisHandle =\n"
    "      makeHandle<vm::JSObject>(thisRes->getHermesValue());\n",
)
replace_once(
    hermes_node_api,
    "  vm::CallResult<bool> res = vm::JSObject::getOwnComputedDescriptor(\n"
    "      makeHandle<vm::JSObject>(object),\n"
    "      runtime_,\n"
    "      makeHandle(key),\n"
    "      tmpSymbolStorage,\n"
    "      desc);\n",
    "  vm::CallResult<bool> res = vm::JSObject::getOwnComputedDescriptor(\n"
    "      makeHandle<vm::JSObject>(object),\n"
    "      runtime_,\n"
    "      makeHandle(key),\n"
    "      desc);\n",
)
replace_once(
    hermes_node_api,
    "  vm::Handle<vm::JSDataView> viewHandle = makeHandle(vm::JSDataView::create(\n"
    "      runtime_, makeHandle<vm::JSObject>(runtime_.dataViewPrototype)));\n",
    "  vm::Handle<vm::JSDataView> viewHandle = makeHandle(vm::JSDataView::create(\n"
    "      runtime_,\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.dataViewPrototype)));\n",
)
replace_once(
    hermes_node_api,
    "    static vm::CallResult<vm::HermesValue>\n"
    "    callback(void *context, vm::Runtime & /*runtime*/, vm::NativeArgs args) {\n"
    "      return (reinterpret_cast<ExecutorData *>(context))->callback(args);\n"
    "    }\n",
    "    static vm::CallResult<vm::HermesValue> callback(\n"
    "        void *context,\n"
    "        vm::Runtime &runtime) {\n"
    "      return (reinterpret_cast<ExecutorData *>(context))\n"
    "          ->callback(runtime.getCurrentFrame().getNativeArgs());\n"
    "    }\n",
)
replace_once(
    hermes_node_api,
    "  vm::Handle<vm::NativeFunction> executorFunction =\n"
    "      vm::NativeFunction::createWithoutPrototype(\n"
    "          runtime_,\n"
    "          &executorData,\n"
    "          &ExecutorData::callback,\n"
    "          getPredefinedSymbol(NodeApiPredefined::Promise),\n"
    "          2);\n",
    "  vm::Handle<vm::NativeFunction> executorFunction = vm::NativeFunction::create(\n"
    "      runtime_,\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.functionPrototype),\n"
    "      vm::Runtime::makeNullHandle<vm::Environment>(),\n"
    "      &executorData,\n"
    "      &ExecutorData::callback,\n"
    "      getPredefinedSymbol(NodeApiPredefined::Promise),\n"
    "      2,\n"
    "      vm::Runtime::makeNullHandle<vm::JSObject>());\n",
)
replace_once(
    hermes_node_api,
    "  vm::Handle<vm::NativeFunction> onUnhandled =\n"
    "      vm::NativeFunction::createWithoutPrototype(\n"
    "          runtime_,\n"
    "          this,\n"
    "          [](void *context,\n"
    "             vm::Runtime &runtime,\n"
    "             vm::NativeArgs args) -> vm::CallResult<vm::HermesValue> {\n"
    "            return handleRejectionNotification(\n"
    "                context,\n"
    "                runtime,\n"
    "                args,\n"
    "                [](NodeApiEnvironment *env, int32_t id, vm::HermesValue error) {\n"
    "                  env->lastUnhandledRejectionId_ = id;\n"
    "                  env->lastUnhandledRejection_ = error;\n"
    "                });\n"
    "          },\n"
    "          getPredefinedValue(NodeApiPredefined::onUnhandled).getSymbol(),\n"
    "          /*paramCount:*/ 2);\n"
    "  vm::Handle<vm::NativeFunction> onHandled =\n"
    "      vm::NativeFunction::createWithoutPrototype(\n"
    "          runtime_,\n"
    "          this,\n"
    "          [](void *context,\n"
    "             vm::Runtime &runtime,\n"
    "             vm::NativeArgs args) -> vm::CallResult<vm::HermesValue> {\n"
    "            return handleRejectionNotification(\n"
    "                context,\n"
    "                runtime,\n"
    "                args,\n"
    "                [](NodeApiEnvironment *env, int32_t id, vm::HermesValue error) {\n"
    "                  if (env->lastUnhandledRejectionId_ == id) {\n"
    "                    env->lastUnhandledRejectionId_ = -1;\n"
    "                    env->lastUnhandledRejection_ = EmptyHermesValue;\n"
    "                  }\n"
    "                });\n"
    "          },\n"
    "          getPredefinedValue(NodeApiPredefined::onHandled).getSymbol(),\n"
    "          /*paramCount:*/ 2);\n",
    "  vm::Handle<vm::NativeFunction> onUnhandled = vm::NativeFunction::create(\n"
    "      runtime_,\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.functionPrototype),\n"
    "      vm::Runtime::makeNullHandle<vm::Environment>(),\n"
    "      this,\n"
    "      [](void *context,\n"
    "         vm::Runtime &runtime) -> vm::CallResult<vm::HermesValue> {\n"
    "        return handleRejectionNotification(\n"
    "            context,\n"
    "            runtime,\n"
    "            runtime.getCurrentFrame().getNativeArgs(),\n"
    "            [](NodeApiEnvironment *env, int32_t id, vm::HermesValue error) {\n"
    "              env->lastUnhandledRejectionId_ = id;\n"
    "              env->lastUnhandledRejection_ = error;\n"
    "            });\n"
    "      },\n"
    "      getPredefinedValue(NodeApiPredefined::onUnhandled).getSymbol(),\n"
    "      /*paramCount:*/ 2,\n"
    "      vm::Runtime::makeNullHandle<vm::JSObject>());\n"
    "  vm::Handle<vm::NativeFunction> onHandled = vm::NativeFunction::create(\n"
    "      runtime_,\n"
    "      vm::Handle<vm::JSObject>::vmcast(&runtime_.functionPrototype),\n"
    "      vm::Runtime::makeNullHandle<vm::Environment>(),\n"
    "      this,\n"
    "      [](void *context,\n"
    "         vm::Runtime &runtime) -> vm::CallResult<vm::HermesValue> {\n"
    "        return handleRejectionNotification(\n"
    "            context,\n"
    "            runtime,\n"
    "            runtime.getCurrentFrame().getNativeArgs(),\n"
    "            [](NodeApiEnvironment *env, int32_t id, vm::HermesValue error) {\n"
    "              if (env->lastUnhandledRejectionId_ == id) {\n"
    "                env->lastUnhandledRejectionId_ = -1;\n"
    "                env->lastUnhandledRejection_ = EmptyHermesValue;\n"
    "              }\n"
    "            });\n"
    "      },\n"
    "      getPredefinedValue(NodeApiPredefined::onHandled).getSymbol(),\n"
    "      /*paramCount:*/ 2,\n"
    "      vm::Runtime::makeNullHandle<vm::JSObject>());\n",
)
replace_once(
    hermes_node_api,
    "  vm::Handle<vm::Callable> hookFunc = vm::Handle<vm::Callable>::dyn_vmcast(\n"
    "      makeHandle(&runtime_.promiseRejectionTrackingHook_));\n",
    "  vm::Handle<vm::Callable> hookFunc =\n"
    "      vm::vmisa<vm::Callable>(runtime_.promiseRejectionTrackingHook_.getHermesValue())\n"
    "      ? vm::Handle<vm::Callable>::vmcast(&runtime_.promiseRejectionTrackingHook_)\n"
    "      : vm::Runtime::makeNullHandle<vm::Callable>();\n",
)
replace_once(
    hermes_node_api,
    "  vm::PseudoHandle<vm::JSDate> dateHandle = vm::JSDate::create(\n"
    "      runtime_, dateTime, makeHandle<vm::JSObject>(&runtime_.datePrototype));\n",
    "  vm::PseudoHandle<vm::JSDate> dateHandle = vm::JSDate::create(\n"
    "      runtime_, dateTime, vm::Handle<vm::JSObject>::vmcast(&runtime_.datePrototype));\n",
)
replace_once(
    hermes_node_api,
    "vm::Handle<> NodeApiEnvironment::makeHandle(vm::HermesValue value) noexcept {\n"
    "  return vm::Handle<>(runtime_, value);\n"
    "}\n",
    "vm::Handle<> NodeApiEnvironment::makeHandle(vm::HermesValue value) noexcept {\n"
    "  return runtime_.makeHandle(value);\n"
    "}\n",
)

apple_build = root / "utils/build-apple-framework.sh"
replace_once(
    apple_build,
    'function build_host_hermesc {\n'
    '  echo "Building hermesc"\n'
    '  pushd "$HERMES_PATH" > /dev/null || exit 1\n'
    '    cmake -S . -B build_host_hermesc -DJSI_DIR="$JSI_PATH" -DCMAKE_BUILD_TYPE=Release\n'
    '    cmake --build ./build_host_hermesc --target hermesc -j "${NUM_CORES}"\n'
    '  popd > /dev/null || exit 1\n'
    '}\n',
    'function sdk_path_for_platform {\n'
    '  local platform="$1"\n'
    '  local sdk="$platform"\n'
    '  case "$platform" in\n'
    '    macosx|macos) sdk="macosx" ;;\n'
    '    catalyst) sdk="macosx" ;;\n'
    '    iphoneos) sdk="iphoneos" ;;\n'
    '    iphonesimulator) sdk="iphonesimulator" ;;\n'
    '    xros) sdk="xros" ;;\n'
    '    xrsimulator) sdk="xrsimulator" ;;\n'
    '    appletvos) sdk="appletvos" ;;\n'
    '    appletvsimulator) sdk="appletvsimulator" ;;\n'
    '  esac\n'
    '  xcrun --sdk "$sdk" --show-sdk-path\n'
    '}\n'
    '\n'
    'function build_host_hermesc {\n'
    '  echo "Building hermesc"\n'
    '  local host_sdk\n'
    '  host_sdk=$(sdk_path_for_platform "macosx")\n'
    '  pushd "$HERMES_PATH" > /dev/null || exit 1\n'
    '    cmake -S . -B build_host_hermesc -DJSI_DIR="$JSI_PATH" -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_SYSROOT="$host_sdk" -DCMAKE_OSX_DEPLOYMENT_TARGET="${MAC_DEPLOYMENT_TARGET:-11.0}"\n'
    '    cmake --build ./build_host_hermesc --target hermesc -j "${NUM_CORES}"\n'
    '  popd > /dev/null || exit 1\n'
    '}\n',
)
replace_once(
    apple_build,
    'function configure_apple_framework {\n'
    '  local enable_debugger cmake_build_type xcode_15_flags xcode_major_version\n',
    'function configure_apple_framework {\n'
    '  local enable_debugger cmake_build_type xcode_15_flags sdk_path\n',
)
replace_once(
    apple_build,
    '  xcode_15_flags=""\n'
    "  xcode_major_version=$(xcodebuild -version | grep -oE '[0-9]*' | head -n 1)\n"
    '  if [[ $xcode_major_version -ge 15 ]]; then\n'
    '    xcode_15_flags="LINKER:-ld_classic"\n'
    '  fi\n',
    '  xcode_15_flags=""\n'
    '  sdk_path=$(sdk_path_for_platform "$1")\n',
)
replace_once(
    apple_build,
    '      -DHERMES_APPLE_TARGET_PLATFORM:STRING="$1" \\\n'
    '      -DCMAKE_OSX_ARCHITECTURES:STRING="$2" \\\n'
    '      -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING="$3" \\\n',
    '      -DHERMES_APPLE_TARGET_PLATFORM:STRING="$1" \\\n'
    '      -DCMAKE_OSX_SYSROOT:STRING="$sdk_path" \\\n'
    '      -DCMAKE_OSX_ARCHITECTURES:STRING="$2" \\\n'
    '      -DCMAKE_OSX_DEPLOYMENT_TARGET:STRING="$3" \\\n',
)

# Keep going even if future upstream drift requires more edits.
PY

export IOS_DEPLOYMENT_TARGET
export MAC_DEPLOYMENT_TARGET
export BUILD_TYPE
export JSI_PATH="${JSI_PATH:-$SRC_DIR/API/jsi}"

note "Building Hermes Apple frameworks"
pushd "$SRC_DIR" >/dev/null
source ./utils/build-apple-framework.sh
build_apple_framework "macosx" "x86_64;arm64" "$MAC_DEPLOYMENT_TARGET"
build_apple_framework "iphoneos" "arm64" "$IOS_DEPLOYMENT_TARGET"
build_apple_framework "iphonesimulator" "x86_64;arm64" "$IOS_DEPLOYMENT_TARGET"

note "Building additional host Hermes tools"
HOST_TOOL_TARGETS=(hbcdump hdb hbc-attribute hbc-deltaprep hbc-diff)
HOST_TOOL_JOBS="${NUM_CORES:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
cmake --build ./build_host_hermesc --target "${HOST_TOOL_TARGETS[@]}" -j "$HOST_TOOL_JOBS"
mkdir -p ./destroot/bin
for tool in "${HOST_TOOL_TARGETS[@]}"; do
  cp "./build_host_hermesc/bin/$tool" "./destroot/bin/$tool"
done
popd >/dev/null

rename_framework() {
  local platform_dir="$1"
  local src_framework="$platform_dir/hermesvm.framework"
  local dst_framework="$platform_dir/hermes.framework"

  rm -rf "$dst_framework"
  cp -R "$src_framework" "$dst_framework"

  if [[ -f "$dst_framework/hermesvm" ]]; then
    mv "$dst_framework/hermesvm" "$dst_framework/hermes"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable hermes' "$dst_framework/Info.plist" || true
  elif [[ -f "$dst_framework/Versions/Current/hermesvm" ]]; then
    mv "$dst_framework/Versions/Current/hermesvm" "$dst_framework/Versions/Current/hermes"
    [[ -L "$dst_framework/hermesvm" ]] && rm "$dst_framework/hermesvm"
    [[ -L "$dst_framework/Versions/A/hermesvm" ]] && rm "$dst_framework/Versions/A/hermesvm"
    ln -sf "Versions/Current/hermes" "$dst_framework/hermes"
    ln -sf "Versions/Current/hermes" "$dst_framework/Versions/A/hermes"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable hermes' "$dst_framework/Versions/Current/Resources/Info.plist" || true
  fi
}

install_headers_into_framework() {
  local framework_path="$1"

  if [[ -d "$framework_path/Versions/Current" ]]; then
    local headers_dir="$framework_path/Versions/Current/Headers"
    rm -rf "$headers_dir"
    mkdir -p "$headers_dir"
    rsync -a "$SRC_DIR/destroot/include/" "$headers_dir/"
    [[ -e "$framework_path/Headers" ]] || ln -s "Versions/Current/Headers" "$framework_path/Headers"
  else
    local headers_dir="$framework_path/Headers"
    rm -rf "$headers_dir"
    mkdir -p "$headers_dir"
    rsync -a "$SRC_DIR/destroot/include/" "$headers_dir/"
  fi
}

note "Packaging NativeScript-friendly hermes.xcframework"
PKG_DIR="$WORK_ROOT/pkg"
rm -rf "$PKG_DIR" "$OUTPUT_XCFRAMEWORK" "$OUTPUT_HEADERS_DIR" "$OUTPUT_TOOLS_DIR"
mkdir -p "$PKG_DIR"

cp -R "$SRC_DIR/destroot/Library/Frameworks/iphoneos" "$PKG_DIR/ios-arm64"
cp -R "$SRC_DIR/destroot/Library/Frameworks/iphonesimulator" "$PKG_DIR/ios-arm64_x86_64-simulator"
cp -R "$SRC_DIR/destroot/Library/Frameworks/macosx" "$PKG_DIR/macos-arm64_x86_64"

rename_framework "$PKG_DIR/ios-arm64"
rename_framework "$PKG_DIR/ios-arm64_x86_64-simulator"
rename_framework "$PKG_DIR/macos-arm64_x86_64"
install_headers_into_framework "$PKG_DIR/ios-arm64/hermes.framework"
install_headers_into_framework "$PKG_DIR/ios-arm64_x86_64-simulator/hermes.framework"
install_headers_into_framework "$PKG_DIR/macos-arm64_x86_64/hermes.framework"

xcodebuild -create-xcframework \
  -framework "$PKG_DIR/ios-arm64/hermes.framework" \
  -framework "$PKG_DIR/ios-arm64_x86_64-simulator/hermes.framework" \
  -framework "$PKG_DIR/macos-arm64_x86_64/hermes.framework" \
  -output "$OUTPUT_XCFRAMEWORK"

mkdir -p "$OUTPUT_HEADERS_DIR" "$OUTPUT_TOOLS_DIR"
rsync -a "$SRC_DIR/destroot/include/" "$OUTPUT_HEADERS_DIR/"
rsync -a "$SRC_DIR/destroot/bin/" "$OUTPUT_TOOLS_DIR/"

note "Done"
echo "Wrote: $OUTPUT_XCFRAMEWORK"
echo "Wrote: $OUTPUT_HEADERS_DIR"
echo "Wrote: $OUTPUT_TOOLS_DIR"
