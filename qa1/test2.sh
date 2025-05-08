#!/bin/bash
# filepath: /root/autodl-tmp/work/test_zkp_tx.sh

# 设置变量
WORK_DIR="/root/autodl-tmp/work"
DOGECOIN_TX="/root/autodl-tmp/dogecoin/src/dogecoin-tx"
DOGECOIN_SRC="/root/autodl-tmp/dogecoin/src"
RESULTS_DIR="$WORK_DIR/test_results"
LOGS_DIR="$RESULTS_DIR/logs"
JSON_FILE="/root/autodl-tmp/qa1/zkp_stack_dip69.json"

# 创建测试目录结构
mkdir -p "$RESULTS_DIR" "$LOGS_DIR"
cd "$WORK_DIR"
echo "当前工作目录: $(pwd)"

echo "=== OP_CHECKZKP 交易创建与解码测试 ==="
echo "使用ZK证明数据: $JSON_FILE"
echo "测试结果保存到: $RESULTS_DIR"

# 检查工具依赖
if ! command -v jq &> /dev/null; then
    echo "错误: 需要jq工具来解析JSON。请安装: apt-get install jq"
    exit 1
fi

# 检查dogecoin-tx是否可用
if [ ! -f "$DOGECOIN_TX" ]; then
    echo "错误: dogecoin-tx工具不存在: $DOGECOIN_TX"
    exit 1
fi

# 检查JSON文件是否存在
if [ ! -f "$JSON_FILE" ]; then
    echo "错误: ZK证明数据文件不存在: $JSON_FILE"
    exit 1
fi

# 读取JSON数据并验证
echo -e "\n1. 验证ZK证明JSON数据"
JSON_DATA=$(cat "$JSON_FILE")
ELEMENT_COUNT=$(echo "$JSON_DATA" | jq 'length')

echo "找到 $ELEMENT_COUNT 个数据元素"
if [ "$ELEMENT_COUNT" -ne 17 ]; then
    echo "警告: 预期17个元素，但找到 $ELEMENT_COUNT 个"
fi

# 保存所有元素到数组并计算总大小
declare -a ZKP_ELEMENTS
TOTAL_BYTES=0

for i in $(seq 0 $((ELEMENT_COUNT-1))); do
    ELEMENT=$(echo "$JSON_DATA" | jq -r ".[$i]")
    ZKP_ELEMENTS[$i]="$ELEMENT"
    ELEMENT_BYTES=$((${#ELEMENT} / 2))
    TOTAL_BYTES=$((TOTAL_BYTES + ELEMENT_BYTES))
    echo "元素 $i: ${ZKP_ELEMENTS[$i]} (${ELEMENT_BYTES} 字节)"
done

echo "ZK证明数据总大小: $TOTAL_BYTES 字节"

# 创建测试函数 - 使用逐步增加元素的方式测试
test_with_elements() {
    local count=$1
    local use_hex_format=$2
    local test_name="elements_${count}"
    
    if [ "$use_hex_format" = true ]; then
        test_name="hex_${test_name}"
    fi
    
    echo -e "\n测试: 使用前 $count 个ZK证明元素 ($test_name)"
    
    # 构建脚本
    SCRIPT_CMD=""
    HEX_SCRIPT=""
    
    for i in $(seq 0 $((count-1))); do
        if [[ -n "${ZKP_ELEMENTS[$i]}" && "${ZKP_ELEMENTS[$i]}" != "null" ]]; then
            if [ "$use_hex_format" = true ]; then
                # 十六进制模式 - 计算长度前缀
                LENGTH=${#ZKP_ELEMENTS[$i]}
                LENGTH_HEX=$(printf "%02x" $((LENGTH/2)))
                HEX_SCRIPT+="$LENGTH_HEX${ZKP_ELEMENTS[$i]}"
            else
                # 常规模式
                SCRIPT_CMD+="0x${ZKP_ELEMENTS[$i]} "
            fi
        fi
    done
    
    # 添加OP_CHECKZKP
    if [ "$use_hex_format" = true ]; then
        HEX_SCRIPT+="b9"
        echo "使用十六进制脚本: $HEX_SCRIPT"
        TX_RESULT=$($DOGECOIN_TX -create outscript=0.001:0x"$HEX_SCRIPT" 2>&1)
    else
        SCRIPT_CMD+="OP_CHECKZKP"
        echo "使用脚本: $SCRIPT_CMD"
        TX_RESULT=$($DOGECOIN_TX -allowallopcodes -create outscript=0.001:"$SCRIPT_CMD" 2>&1)
    fi
    
    # 保存结果和日志
    echo "$TX_RESULT" > "$LOGS_DIR/${test_name}_tx_result.log"
    
    # 检查创建结果
    if [[ "$TX_RESULT" == *"error"* ]]; then
        echo "✗ 交易创建失败"
        echo "错误信息: $TX_RESULT"
        return 1
    else
        echo "✓ 交易创建成功"
        echo "$TX_RESULT" > "$RESULTS_DIR/${test_name}_tx.hex"
        
        # 尝试解码交易
        echo "尝试解码交易..."
        DECODE_RESULT=$($DOGECOIN_TX -json $(cat "$RESULTS_DIR/${test_name}_tx.hex") 2>&1)
        echo "$DECODE_RESULT" > "$LOGS_DIR/${test_name}_decode_result.log"
        
        if [[ "$DECODE_RESULT" == *"error"* ]]; then
            echo "✗ 交易解码失败"
            # 提取和分析错误
            if [[ "$DECODE_RESULT" == *"asm"*"[error]"* ]]; then
                echo "错误类型: 脚本ASM解析错误"
                # 计算脚本hex长度
                if [[ "$DECODE_RESULT" == *"\"hex\": \""*"\""* ]]; then
                    HEX_PART=$(echo "$DECODE_RESULT" | grep -o '"hex": "[^"]*"' | cut -d'"' -f4)
                    HEX_LENGTH=${#HEX_PART}
                    HEX_BYTES=$((HEX_LENGTH / 2))
                    echo "脚本十六进制长度: $HEX_LENGTH 字符 ($HEX_BYTES 字节)"
                    
                    # 检查是否接近脚本大小限制
                    if [ $HEX_BYTES -gt 9000 ]; then
                        echo "警告: 脚本大小接近或超过限制 (10KB)"
                    fi
                fi
            else
                echo "错误信息: $DECODE_RESULT"
            fi
            return 2
        else
            echo "✓ 交易解码成功"
            echo "$DECODE_RESULT" > "$RESULTS_DIR/${test_name}_tx.json"
            return 0
        fi
    fi
}

# 测试2 - 渐进式测试，找出脚本大小限制
echo -e "\n2. 渐进式测试不同数量的ZK证明元素"

# 测试不同元素数量的交易创建和解码
test_sizes=(1 2 3 4 5 8 12 $ELEMENT_COUNT)
for size in "${test_sizes[@]}"; do
    if [ $size -le $ELEMENT_COUNT ]; then
        test_with_elements $size false
        echo "--------------------------"
    fi
done

# 测试十六进制格式的交易
echo -e "\n3. 测试十六进制格式的交易"
test_with_elements 4 true

# 使用OP_RETURN测试
echo -e "\n4. 使用OP_RETURN创建包含ZK证明数据的交易"

# 尝试使用不同大小的数据元素
for i in 0 1 2; do
    if [[ -n "${ZKP_ELEMENTS[$i]}" && "${ZKP_ELEMENTS[$i]}" != "null" ]]; then
        OP_RETURN_DATA="${ZKP_ELEMENTS[$i]}"
        ELEMENT_BYTES=$((${#OP_RETURN_DATA} / 2))
        
        echo "使用元素 $i 作为OP_RETURN数据 ($ELEMENT_BYTES 字节): $OP_RETURN_DATA"
        TX_RESULT=$($DOGECOIN_TX -create outdata=0:"$OP_RETURN_DATA" 2>&1)
        
        # 保存结果
        echo "$TX_RESULT" > "$LOGS_DIR/opreturn_${i}_result.log"
        
        if [[ "$TX_RESULT" == *"error"* ]]; then
            echo "✗ OP_RETURN交易创建失败: $TX_RESULT"
        else
            echo "✓ OP_RETURN交易创建成功"
            echo "$TX_RESULT" > "$RESULTS_DIR/opreturn_${i}_tx.hex"
            
            # 尝试解码
            DECODE_RESULT=$($DOGECOIN_TX -json $(cat "$RESULTS_DIR/opreturn_${i}_tx.hex") 2>&1)
            if [[ "$DECODE_RESULT" == *"error"* ]]; then
                echo "✗ OP_RETURN交易解码失败: $DECODE_RESULT"
            else
                echo "✓ OP_RETURN交易解码成功"
                echo "$DECODE_RESULT" > "$RESULTS_DIR/opreturn_${i}_tx.json"
            fi
        fi
        echo "--------------------------"
    fi
done

# 总结测试结果
echo -e "\n=== 测试总结 ==="
echo "1. ZK证明数据:"
echo "   - 总元素数: $ELEMENT_COUNT"
echo "   - 总数据大小: $TOTAL_BYTES 字节"
echo "2. 交易创建测试:"

# 检查各种大小的测试结果
for size in "${test_sizes[@]}"; do
    if [ $size -le $ELEMENT_COUNT ]; then
        STATUS="失败"
        if [ -f "$RESULTS_DIR/elements_${size}_tx.hex" ]; then 
            STATUS="成功"
            if [ -f "$RESULTS_DIR/elements_${size}_tx.json" ]; then
                STATUS="成功 (解码成功)"
            else
                STATUS="成功 (解码失败)"
            fi
        fi
        echo "   - $size 个元素: $STATUS"
    fi
done

echo "3. 十六进制格式测试:"
if [ -f "$RESULTS_DIR/hex_elements_4_tx.hex" ]; then
    HEX_STATUS="成功"
    if [ -f "$RESULTS_DIR/hex_elements_4_tx.json" ]; then
        HEX_STATUS="成功 (解码成功)"
    else
        HEX_STATUS="成功 (解码失败)"
    fi
else
    HEX_STATUS="失败"
fi
echo "   - 十六进制格式: $HEX_STATUS"

# 检查OP_RETURN测试结果
echo "4. OP_RETURN测试:"
for i in 0 1 2; do
    if [ -f "$RESULTS_DIR/opreturn_${i}_tx.hex" ]; then
        OP_STATUS="成功"
        if [ -f "$RESULTS_DIR/opreturn_${i}_tx.json" ]; then
            OP_STATUS="成功 (解码成功)"
        else
            OP_STATUS="成功 (解码失败)"
        fi
    else
        OP_STATUS="失败"
    fi
    # 只有当有结果文件时才显示
    if [ -f "$LOGS_DIR/opreturn_${i}_result.log" ]; then
        echo "   - 元素 $i: $OP_STATUS"
    fi
done

echo -e "\n可能的错误原因分析:"
echo "1. 脚本大小限制 - 交易脚本可能超过Dogecoin的最大允许大小"
echo "2. 数据格式问题 - 解码器可能无法正确解析长字节序列"
echo "3. OP_CHECKZKP实现 - 操作码存在但完整实现尚未完成"

echo -e "\n详细日志和结果已保存到 $RESULTS_DIR 和 $LOGS_DIR"