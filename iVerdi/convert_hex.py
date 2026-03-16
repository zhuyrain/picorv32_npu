# -*- coding: utf-8 -*-
import sys

def convert_hex(input_file, output_file):
    with open(input_file, 'r') as f:
        lines = f.readlines()

    byte_list = []
    for line in lines:
        line = line.strip()
        if line.startswith('@'):
            continue
        # 按空格分割出每一个 byte
        tokens = line.split()
        byte_list.extend(tokens)

    # 如果字节数不是 4 的倍数，在末尾补 00
    while len(byte_list) % 4 != 0:
        byte_list.append("00")

    with open(output_file, 'w') as f:
        # 每次取 4 个字节，按小端序拼接
        for i in range(0, len(byte_list), 4):
            byte0 = byte_list[i]
            byte1 = byte_list[i+1]
            byte2 = byte_list[i+2]
            byte3 = byte_list[i+3]
            
            # 小端序：高地址放在高位
            word_32bit = byte3 + byte2 + byte1 + byte0
            f.write(word_32bit + '\n')

if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: python pack_hex.py <input.hex> <output.hex>")
        sys.exit(1)
    
    convert_hex(sys.argv[1], sys.argv[2])
    print(f"Successfully packed {sys.argv[1]} into 32-bit words in {sys.argv[2]}")