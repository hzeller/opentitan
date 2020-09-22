// Copyright lowRISC contributors.
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// SECDED Encoder generated by secded_gen.py

module prim_secded_22_16_enc (
  input        [15:0] in,
  output logic [21:0] out
);

  assign out[0]  = in[0];
  assign out[1]  = in[1];
  assign out[2]  = in[2];
  assign out[3]  = in[3];
  assign out[4]  = in[4];
  assign out[5]  = in[5];
  assign out[6]  = in[6];
  assign out[7]  = in[7];
  assign out[8]  = in[8];
  assign out[9]  = in[9];
  assign out[10] = in[10];
  assign out[11] = in[11];
  assign out[12] = in[12];
  assign out[13] = in[13];
  assign out[14] = in[14];
  assign out[15] = in[15];
  assign out[16] = in[0] ^ in[1] ^ in[5] ^ in[8] ^ in[9] ^ in[10] ^ in[11] ^ in[15];
  assign out[17] = in[0] ^ in[4] ^ in[5] ^ in[6] ^ in[8] ^ in[12] ^ in[13] ^ in[14];
  assign out[18] = in[1] ^ in[3] ^ in[4] ^ in[6] ^ in[7] ^ in[8] ^ in[10] ^ in[13];
  assign out[19] = in[1] ^ in[2] ^ in[3] ^ in[11] ^ in[12] ^ in[13] ^ in[14] ^ in[15];
  assign out[20] = in[2] ^ in[3] ^ in[5] ^ in[6] ^ in[7] ^ in[9] ^ in[11] ^ in[12];
  assign out[21] = in[0] ^ in[2] ^ in[4] ^ in[7] ^ in[9] ^ in[10] ^ in[14] ^ in[15];
endmodule

