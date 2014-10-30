#!/usr/bin/lua

require 'gmp'

gmp.set_default_prec(128)

n = 1234567890 + 1/2^11
f = gmp.f(n)

print(n)
print(f,type(f))
print(f:get_prec())
print(f:get_d(), type(f:get_d()))
print(f:get_d_2exp())

