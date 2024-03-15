/* Copyright 2021 The TensorFlow Authors. All Rights Reserved.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
==============================================================================*/
#include "tensorflow/compiler/mlir/lite/stablehlo/transforms/stablehlo_tfl_pass.h"

#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "flatbuffers/flatbuffers.h"  // from @flatbuffers
#include "flatbuffers/flexbuffers.h"  // from @flatbuffers
#include "mlir/Dialect/Func/IR/FuncOps.h"  // from @llvm-project
#include "mlir/IR/Attributes.h"  // from @llvm-project
#include "mlir/IR/Block.h"  // from @llvm-project
#include "mlir/IR/Builders.h"  // from @llvm-project
#include "mlir/IR/BuiltinAttributes.h"  // from @llvm-project
#include "mlir/IR/BuiltinOps.h"  // from @llvm-project
#include "mlir/IR/Diagnostics.h"  // from @llvm-project
#include "mlir/IR/MLIRContext.h"  // from @llvm-project
#include "mlir/IR/Operation.h"  // from @llvm-project
#include "mlir/IR/OperationSupport.h"  // from @llvm-project
#include "mlir/IR/PatternMatch.h"  // from @llvm-project
#include "mlir/IR/Value.h"  // from @llvm-project
#include "mlir/Pass/Pass.h"  // from @llvm-project
#include "mlir/Pass/PassRegistry.h"  // from @llvm-project
#include "mlir/Support/LLVM.h"  // from @llvm-project
#include "mlir/Support/LogicalResult.h"  // from @llvm-project
#include "mlir/Transforms/DialectConversion.h"  // from @llvm-project
#include "stablehlo/dialect/StablehloOps.h"  // from @stablehlo
#include "tensorflow/compiler/mlir/lite/ir/tfl_ops.h"

namespace mlir {
namespace odml {

class StablehloToTflPass
    : public mlir::PassWrapper<StablehloToTflPass,
                               mlir::OperationPass<mlir::func::FuncOp>> {
 public:
  explicit StablehloToTflPass() : PassWrapper() {}
  StringRef getArgument() const final { return "stablehlo-tfl"; }
  StringRef getDescription() const final {
    return "This pass will legalize StableHLO Ops to TFLite custom Ops.";
  }

 private:
  void runOnOperation() override;

  void getDependentDialects(DialectRegistry& registry) const override {
    registry.insert<TFL::TensorFlowLiteDialect>();
  }
};

namespace {
TFL::ConstBytesAttr CustomOption(OpBuilder* builder,
                                 const std::string& content) {
  return TFL::ConstBytesAttr::get(builder->getContext(),
                                  StringRef(content.data(), content.size()));
}

void AddIntegerArray(flexbuffers::Builder* fbb, ::llvm::ArrayRef<int64_t> vec) {
  auto start_input_dim = fbb->StartVector();
  for (auto int_value : vec) {
    fbb->Add(int_value);
  }
  fbb->EndVector(start_input_dim, /*typed=*/false, /*fixed=*/false);
}

LogicalResult BuildOption(flexbuffers::Builder* fbb, Operation* op,
                          NamedAttribute pair) {
  const char* key = pair.getName().data();
  const auto attr = pair.getValue();

  if (attr.isa<::mlir::IntegerAttr>()) {
    fbb->Int(key, attr.dyn_cast<mlir::IntegerAttr>().getInt());
    return success();
  }

  if (attr.isa<::mlir::FloatAttr>()) {
    fbb->Double(key, attr.dyn_cast<mlir::FloatAttr>().getValueAsDouble());
    return success();
  }

  if (attr.isa<::mlir::ElementsAttr>()) {
    auto start = fbb->StartVector(key);
    auto array_attr = attr.dyn_cast<mlir::ElementsAttr>();
    const auto ftype = array_attr.getElementType();
    if (ftype.isInteger(16) || ftype.isInteger(32) || ftype.isInteger(64) ||
        ftype.isInteger(128) || ftype.isInteger(1)) {
      for (auto value : array_attr.getValues<IntegerAttr>()) {
        auto int_value = value.dyn_cast_or_null<mlir::IntegerAttr>().getInt();
        fbb->Add(int_value);
      }
    } else if (ftype.isF32() || ftype.isF64() || ftype.isF128()) {
      for (auto value : array_attr.getValues<FloatAttr>()) {
        auto double_value =
            value.dyn_cast_or_null<mlir::FloatAttr>().getValueAsDouble();
        fbb->Add(double_value);
      }
    } else {
      emitWarning(op->getLoc(), "serialization of ElementsAttr for ")
          << key << " only supports Integer and Float.";
    }
    fbb->EndVector(start, /*typed=*/true, /*fixed=*/false);
    return success();
  }

  if (attr.isa<::mlir::DenseI64ArrayAttr>()) {
    auto array_attr = attr.dyn_cast<mlir::DenseI64ArrayAttr>();
    auto start = fbb->StartVector(key);
    for (auto int_value : array_attr.asArrayRef()) {
      fbb->Add(int_value);
    }
    fbb->EndVector(start, /*typed=*/true, /*fixed=*/false);
    return success();
  }

  if (attr.isa<::mlir::DenseBoolArrayAttr>()) {
    auto array_attr = attr.dyn_cast<mlir::DenseBoolArrayAttr>();
    auto start = fbb->StartVector(key);
    for (auto bool_value : array_attr.asArrayRef()) {
      fbb->Add(bool_value);
    }
    fbb->EndVector(start, /*typed=*/true, /*fixed=*/false);
    return success();
  }

  if (attr.isa<::mlir::StringAttr>()) {
    fbb->String(key, attr.dyn_cast<mlir::StringAttr>().data());
    return success();
  }

  if (attr.isa<::mlir::ArrayAttr>()) {
    auto start = fbb->StartVector(key);
    auto array_attr = attr.dyn_cast<mlir::ArrayAttr>();
    if (array_attr.size() > 1 && !array_attr[0].isa<mlir::StringAttr>() &&
        !array_attr[0].isa<mlir::stablehlo::PrecisionAttr>()) {
      emitWarning(op->getLoc(), "serialization of ArrayAttr for ")
          << key << " only supports Strings.";
      return success();
    }
    for (auto value : array_attr) {
      if (value.isa<mlir::stablehlo::PrecisionAttr>()) {
        auto string_value =
            mlir::stablehlo::stringifyPrecision(
                value.cast<mlir::stablehlo::PrecisionAttr>().getValue())
                .data();
        fbb->Add(string_value);
      } else {
        auto string_value = value.dyn_cast_or_null<mlir::StringAttr>().data();
        fbb->Add(string_value);
      }
    }
    fbb->EndVector(start, /*typed=*/true, /*fixed=*/false);
    return success();
  }

  if (attr.isa<::mlir::stablehlo::ConvDimensionNumbersAttr>()) {
    auto dimension_attr =
        attr.dyn_cast<::mlir::stablehlo::ConvDimensionNumbersAttr>();
    auto start = fbb->StartVector(key);
    fbb->Add(dimension_attr.getInputBatchDimension());
    fbb->Add(dimension_attr.getInputFeatureDimension());
    AddIntegerArray(fbb, dimension_attr.getInputSpatialDimensions());
    fbb->Add(dimension_attr.getKernelInputFeatureDimension());
    fbb->Add(dimension_attr.getKernelOutputFeatureDimension());
    AddIntegerArray(fbb, dimension_attr.getKernelSpatialDimensions());
    fbb->Add(dimension_attr.getOutputBatchDimension());
    fbb->Add(dimension_attr.getOutputFeatureDimension());
    AddIntegerArray(fbb, dimension_attr.getOutputSpatialDimensions());
    fbb->EndVector(start, /*typed=*/false, /*fixed=*/false);
    return success();
  }

  if (attr.isa<::mlir::stablehlo::GatherDimensionNumbersAttr>()) {
    auto dimension_attr =
        attr.dyn_cast<::mlir::stablehlo::GatherDimensionNumbersAttr>();
    auto start = fbb->StartVector(key);
    AddIntegerArray(fbb, dimension_attr.getOffsetDims());
    AddIntegerArray(fbb, dimension_attr.getCollapsedSliceDims());
    AddIntegerArray(fbb, dimension_attr.getStartIndexMap());
    fbb->Add(dimension_attr.getIndexVectorDim());
    fbb->EndVector(start, /*typed=*/false, /*fixed=*/false);
    return success();
  }

  if (attr.isa<::mlir::stablehlo::ScatterDimensionNumbersAttr>()) {
    auto dimension_attr =
        attr.dyn_cast<::mlir::stablehlo::ScatterDimensionNumbersAttr>();
    auto start = fbb->StartVector(key);
    AddIntegerArray(fbb, dimension_attr.getUpdateWindowDims());
    AddIntegerArray(fbb, dimension_attr.getInsertedWindowDims());
    AddIntegerArray(fbb, dimension_attr.getScatterDimsToOperandDims());
    fbb->Add(dimension_attr.getIndexVectorDim());
    fbb->EndVector(start, /*typed=*/false, /*fixed=*/false);
    return success();
  }

  if (attr.isa<::mlir::stablehlo::DotDimensionNumbersAttr>()) {
    auto dimension_attr =
        attr.dyn_cast<::mlir::stablehlo::DotDimensionNumbersAttr>();
    auto start = fbb->StartVector(key);
    AddIntegerArray(fbb, dimension_attr.getLhsBatchingDimensions());
    AddIntegerArray(fbb, dimension_attr.getRhsBatchingDimensions());
    AddIntegerArray(fbb, dimension_attr.getLhsContractingDimensions());
    AddIntegerArray(fbb, dimension_attr.getRhsContractingDimensions());
    fbb->EndVector(start, /*typed=*/false, /*fixed=*/false);
    return success();
  }

  if (attr.isa<::mlir::stablehlo::ComparisonDirectionAttr>()) {
    auto string_value =
        mlir::stablehlo::stringifyComparisonDirection(
            attr.cast<mlir::stablehlo::ComparisonDirectionAttr>().getValue())
            .str();
    fbb->String(key, string_value);
    return success();
  }

  if (attr.isa<::mlir::stablehlo::ComparisonTypeAttr>()) {
    auto string_value =
        mlir::stablehlo::stringifyComparisonType(
            attr.cast<mlir::stablehlo::ComparisonTypeAttr>().getValue())
            .str();
    fbb->String(key, string_value);
    return success();
  }

  // default
  return emitWarning(op->getLoc(), "serialization not supported for : ") << key;
}

bool IsSupportedComposite(stablehlo::CompositeOp op) {
  // List of supported composites to represent using CustomOp.
  StringRef op_name = op.getName();
  for (auto supported :
       {"odml.update_kv_cache", "odml.scaled_dot_product_attention"}) {
    if (op_name == supported) return true;
  }
  emitWarning(op->getLoc(), "composite has no specializaiton ") << op.getName();
  return false;
}

}  // namespace

void StablehloToTflPass::runOnOperation() {
  func::FuncOp fn = getOperation();
  OpBuilder builder(fn.getContext());
  fn.walk([&](Operation* op) {
    // Process only StableHLO ops.
    if (op->getDialect()->getNamespace() != "stablehlo") return;

    // Get op name and attributes, unpacks some composites
    StringRef custom_op_name = op->getName().getStringRef();
    SmallVector<NamedAttribute> options;
    auto composite = llvm::dyn_cast<mlir::stablehlo::CompositeOp>(op);
    if (composite && IsSupportedComposite(composite)) {
      // stablehlo.composite "odml.some_op" <args> {composite_attrs = <attrs> }
      // ==> tfl.custom(<args>) { name = "odml.some_op", <attrs...> }
      custom_op_name = composite.getName();
      auto composite_attrs = composite.getCompositeAttributes();
      options.append(composite_attrs.begin(), composite_attrs.end());
    } else {
      options = llvm::to_vector(op->getAttrDictionary().getValue());
    }

    // Build options.
    std::string custom_option_buffer;
    auto fbb = std::make_unique<flexbuffers::Builder>();
    size_t map_start = fbb->StartMap();
    for (auto pair : options) {
      // Allows silently skipping unsupported attributes.
      (void)BuildOption(fbb.get(), op, pair);
    }
    fbb->EndMap(map_start);
    fbb->Finish();
    custom_option_buffer.assign(fbb->GetBuffer().begin(),
                                fbb->GetBuffer().end());

    // Build custom op.
    builder.setInsertionPoint(op);
    auto tfl_custom_op = builder.create<TFL::CustomOp>(
        op->getLoc(), op->getResultTypes(), op->getOperands(), custom_op_name,
        CustomOption(&builder, custom_option_buffer));
    op->replaceAllUsesWith(tfl_custom_op);
    op->erase();
  });
}
std::unique_ptr<OperationPass<func::FuncOp>> CreateStablehloToTflPass() {
  return std::make_unique<StablehloToTflPass>();
}

static PassRegistration<StablehloToTflPass> pass;

}  // namespace odml
}  // namespace mlir
